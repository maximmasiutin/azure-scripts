# create-192core-vm.ps1
# Creates a 192-core Azure Spot VM with SSH enabled
# Automatically finds cheapest VM size and region, checks quota before creating

[CmdletBinding()]
param(
    [string]$VMName = "vm-192core",
    [string]$Location,  # Auto-detect if not specified
    [string]$VMSize,    # Auto-detect if not specified
    [int]$MinCores = 192,
    [int]$MaxCores = 192,
    [string]$ResourceGroupName,  # Defaults to RG-$VMName
    [switch]$WhatIf  # Show what would be done without creating
)

$ErrorActionPreference = "Stop"

# Check required environment variables
$missing = @()
if (-not $env:AZURE_SSH_PUBLIC_KEY) { $missing += "AZURE_SSH_PUBLIC_KEY" }
if (-not $env:AZURE_VM_USERNAME) { $missing += "AZURE_VM_USERNAME" }
if (-not $env:AZURE_VM_PASSWORD) { $missing += "AZURE_VM_PASSWORD" }

if ($missing.Count -gt 0) {
    Write-Host "ERROR: Required environment variables not set: $($missing -join ', ')" -ForegroundColor Red
    Write-Host ""
    Write-Host "Please set the following environment variables:" -ForegroundColor Yellow
    Write-Host "  `$env:AZURE_SSH_PUBLIC_KEY = 'ssh-ed25519 AAAA... user@host'"
    Write-Host "  `$env:AZURE_VM_USERNAME = 'yourusername'"
    Write-Host "  `$env:AZURE_VM_PASSWORD = 'YourSecurePassword123'"
    exit 1
}

# Set default resource group
if (-not $ResourceGroupName) {
    $ResourceGroupName = "RG-$VMName"
}

# Find cheapest VM if not specified
if (-not $VMSize -or -not $Location) {
    Write-Host "Finding cheapest $MinCores-core spot VM..." -ForegroundColor Cyan

    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $priceScript = Join-Path $scriptDir "vm-spot-price.py"

    # Restricted regions that don't support full VM operations (no VNet, no quota API)
    $restrictedRegions = @(
        "australiacentral2",
        "francesouth",
        "germanynorth",
        "norwaywest",
        "southafricawest",
        "switzerlandwest",
        "uaecentral",
        "westindia"
    )
    $excludeRegionsArg = $restrictedRegions -join ","

    # Query for cheapest VM with specified core count, exclude ARM and restricted regions
    $priceArgs = @(
        $priceScript,
        "--min-cores", $MinCores,
        "--max-cores", $MaxCores,
        "--exclude-arm",
        "--exclude-regions", $excludeRegionsArg,
        "--return-region",
        "--top", "1"
    )

    # Run Python script as background job with progress indicator
    $startTime = Get-Date
    $expectedDuration = 120  # Expected duration in seconds for 192-core query
    $tempOutput = [System.IO.Path]::GetTempFileName()
    $tempError = [System.IO.Path]::GetTempFileName()

    $process = Start-Process -FilePath "python" -ArgumentList $priceArgs -NoNewWindow -PassThru `
        -RedirectStandardOutput $tempOutput -RedirectStandardError $tempError

    # Show progress while waiting
    $spinner = @('|', '/', '-', '\')
    $spinIdx = 0
    while (-not $process.HasExited) {
        $elapsed = ((Get-Date) - $startTime).TotalSeconds
        $remaining = [math]::Max(0, $expectedDuration - $elapsed)
        $pct = [math]::Min(99, [math]::Round(($elapsed / $expectedDuration) * 100))
        $spinChar = $spinner[$spinIdx % 4]
        $spinIdx++

        $status = "Querying Azure pricing API... $spinChar  Elapsed: {0:N0}s  ETA: {1:N0}s remaining" -f $elapsed, $remaining
        Write-Host "`r$status" -NoNewline -ForegroundColor Yellow
        Start-Sleep -Seconds 5
    }
    Write-Host "`r$(' ' * 80)" -NoNewline  # Clear the line
    Write-Host "`rQuery completed in $([math]::Round(((Get-Date) - $startTime).TotalSeconds))s" -ForegroundColor Cyan

    # Read output
    $result = Get-Content $tempOutput -Raw -ErrorAction SilentlyContinue
    $errorOutput = Get-Content $tempError -Raw -ErrorAction SilentlyContinue
    $exitCode = $process.ExitCode

    # Cleanup temp files
    Remove-Item $tempOutput -Force -ErrorAction SilentlyContinue
    Remove-Item $tempError -Force -ErrorAction SilentlyContinue

    if ($exitCode -ne 0 -or -not $result) {
        Write-Host "ERROR: Could not find available VM with $MinCores cores" -ForegroundColor Red
        if ($errorOutput) { Write-Host $errorOutput -ForegroundColor Yellow }
        if ($result) { Write-Host $result -ForegroundColor Yellow }
        exit 1
    }

    # Parse result: "region vmsize price unit"
    $result = $result.Trim()
    $parts = $result -split '\s+'
    if ($parts.Count -lt 2) {
        Write-Host "ERROR: Unexpected output from vm-spot-price.py: $result" -ForegroundColor Red
        exit 1
    }

    if (-not $Location) { $Location = $parts[0] }
    if (-not $VMSize) {
        # vm-spot-price.py returns VM size without "Standard_" prefix
        $vmSizeRaw = $parts[1]
        if ($vmSizeRaw -like "Standard_*") {
            $VMSize = $vmSizeRaw
        } else {
            $VMSize = "Standard_$vmSizeRaw"
        }
    }

    $price = if ($parts.Count -ge 3) { $parts[2] } else { "unknown" }
    Write-Host "Found: $VMSize in $Location at `$$price/hour" -ForegroundColor Green
}

# Check quota
Write-Host ""
Write-Host "Checking spot quota in $Location..." -ForegroundColor Cyan

try {
    $usage = Get-AzVMUsage -Location $Location -ErrorAction Stop
    $spotQuota = $usage | Where-Object { $_.Name.Value -eq "lowPriorityCores" }

    if ($spotQuota) {
        $available = $spotQuota.Limit - $spotQuota.CurrentValue

        # Extract core count from VM size (e.g., E192as_v5 -> 192)
        $required = 0
        if ($VMSize -match '(\d+)') {
            $required = [int]$Matches[1]
        }

        Write-Host "Spot quota: $($spotQuota.CurrentValue)/$($spotQuota.Limit) used, $available available, need $required" -ForegroundColor White

        if ($available -lt $required) {
            Write-Host "ERROR: Insufficient spot quota in $Location. Need $required cores, only $available available." -ForegroundColor Red
            Write-Host "Request quota increase at: https://portal.azure.com/#blade/Microsoft_Azure_Capacity/QuotaMenuBlade" -ForegroundColor Yellow
            exit 1
        }
        Write-Host "Quota check passed" -ForegroundColor Green
    } else {
        Write-Host "WARNING: Could not verify spot quota (lowPriorityCores not found)" -ForegroundColor Yellow
    }
} catch {
    Write-Host "WARNING: Could not check quota: $_" -ForegroundColor Yellow
}

# Summary
Write-Host ""
Write-Host "=== VM Creation Summary ===" -ForegroundColor Cyan
Write-Host "  VM Name:     $VMName"
Write-Host "  Location:    $Location"
Write-Host "  VM Size:     $VMSize"
Write-Host "  RG:          $ResourceGroupName"
Write-Host "  Username:    $env:AZURE_VM_USERNAME"
Write-Host "  SSH Key:     $($env:AZURE_SSH_PUBLIC_KEY.Substring(0, [Math]::Min(50, $env:AZURE_SSH_PUBLIC_KEY.Length)))..."
Write-Host ""

if ($WhatIf) {
    Write-Host "WhatIf: Would create VM with above settings" -ForegroundColor Yellow
    exit 0
}

# Create VM
Write-Host "Creating VM..." -ForegroundColor Cyan

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$createScript = Join-Path $scriptDir "create-spot-vms.ps1"

& $createScript `
    -VMName $VMName `
    -Location $Location `
    -VMSize $VMSize `
    -ResourceGroupName $ResourceGroupName `
    -SshPublicKey $env:AZURE_SSH_PUBLIC_KEY `
    -SuppressWarnings

Write-Host ""
Write-Host "Done." -ForegroundColor Green
