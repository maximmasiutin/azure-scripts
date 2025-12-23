# register-preview-features.ps1
# Registers Azure preview features for a provider namespace
# Copyright 2023-2025 by Maxim Masiutin. All rights reserved.
#
# Features:
#   - Bulk registration: Registers all unregistered features in one run
#   - Graceful error handling: Skips features that don't support self-registration
#   - Progress tracking: Shows registration status for each feature
#   - Export support: Save results to CSV for documentation
#
# Switches:
#   -ProviderNamespace  Filter to specific provider (e.g., "Microsoft.Compute")
#   -ListOnly           List features without registering
#   -UnregisteredOnly   Only show/process unregistered features
#   -Force              Skip confirmation prompt
#   -WhatIf             Show what would be registered
#
# Examples:
#   pwsh register-preview-features.ps1 -ProviderNamespace "Microsoft.Compute" -Force
#   pwsh register-preview-features.ps1 -ListOnly
#   pwsh register-preview-features.ps1 -WhatIf
#
# Requires: Azure PowerShell module (Az), Contributor/Owner role

<#
.SYNOPSIS
    Lists and registers Azure preview features across all resource providers.

.DESCRIPTION
    This script discovers all available Azure preview features and attempts to register
    unregistered ones. Some features require Microsoft approval and will show as "Pending".

.PARAMETER ProviderNamespace
    Optional. Filter to specific provider namespace (e.g., "Microsoft.Compute").
    If not specified, processes all providers.

.PARAMETER ListOnly
    Only list available features without registering them.

.PARAMETER UnregisteredOnly
    Only show/process features that are not yet registered.

.PARAMETER ExportPath
    Path to export results as CSV file.

.PARAMETER WhatIf
    Show what would be registered without actually registering.

.EXAMPLE
    .\register-preview-features.ps1 -ListOnly
    Lists all available preview features.

.EXAMPLE
    .\register-preview-features.ps1 -ProviderNamespace "Microsoft.Compute"
    Registers all unregistered Microsoft.Compute preview features.

.EXAMPLE
    .\register-preview-features.ps1 -UnregisteredOnly -ExportPath "features.csv"
    Registers all unregistered features and exports results to CSV.

.EXAMPLE
    .\register-preview-features.ps1 -WhatIf
    Shows what features would be registered without making changes.

.NOTES
    Requires Azure PowerShell module (Az) and Contributor/Owner role.
    Some features require Microsoft approval and cannot be self-registered.
    See: https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/preview-features
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string]$ProviderNamespace,

    [Parameter(Mandatory = $false)]
    [switch]$ListOnly,

    [Parameter(Mandatory = $false)]
    [switch]$UnregisteredOnly,

    [Parameter(Mandatory = $false)]
    [string]$ExportPath,

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# Suppress Azure PowerShell breaking change warnings
$env:SuppressAzurePowerShellBreakingChangeWarnings = "true"

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "INFO"    { "White" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
        "SUCCESS" { "Green" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Test-AzureConnection {
    try {
        $context = Get-AzContext
        if (-not $context) {
            Write-Log "Not connected to Azure. Please run Connect-AzAccount first." "ERROR"
            return $false
        }
        Write-Log "Connected to subscription: $($context.Subscription.Name) ($($context.Subscription.Id))" "INFO"
        return $true
    }
    catch {
        Write-Log "Failed to check Azure connection: $_" "ERROR"
        return $false
    }
}

function Get-AllPreviewFeatures {
    param(
        [string]$Namespace,
        [switch]$UnregisteredOnly
    )

    Write-Log "Retrieving preview features..." "INFO"

    try {
        if ($Namespace) {
            Write-Log "Filtering by namespace: $Namespace" "INFO"
            $features = Get-AzProviderFeature -ProviderNamespace $Namespace -ListAvailable
        }
        else {
            $features = Get-AzProviderFeature -ListAvailable
        }

        if ($UnregisteredOnly) {
            $features = $features | Where-Object {
                $_.RegistrationState -eq "Unregistered" -or
                $_.RegistrationState -eq "NotRegistered"
            }
        }

        Write-Log "Found $($features.Count) features" "INFO"
        return $features
    }
    catch {
        Write-Log "Failed to retrieve features: $_" "ERROR"
        return @()
    }
}

function Register-PreviewFeature {
    param(
        [string]$FeatureName,
        [string]$ProviderNamespace
    )

    try {
        $result = Register-AzProviderFeature -FeatureName $FeatureName -ProviderNamespace $ProviderNamespace
        return @{
            FeatureName       = $FeatureName
            ProviderNamespace = $ProviderNamespace
            State             = $result.RegistrationState
            Success           = $true
            Error             = $null
        }
    }
    catch {
        $errorMsg = $_.Exception.Message
        # Check for common error patterns
        if ($errorMsg -match "does not support registration" -or
            $errorMsg -match "FeatureRegistrationUnsupported") {
            return @{
                FeatureName       = $FeatureName
                ProviderNamespace = $ProviderNamespace
                State             = "Unsupported"
                Success           = $false
                Error             = "Feature does not support self-registration"
            }
        }
        return @{
            FeatureName       = $FeatureName
            ProviderNamespace = $ProviderNamespace
            State             = "Failed"
            Success           = $false
            Error             = $errorMsg
        }
    }
}

# Main script execution
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Azure Preview Features Registration  " -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Check Azure connection
if (-not (Test-AzureConnection)) {
    exit 1
}

# Get features
$features = Get-AllPreviewFeatures -Namespace $ProviderNamespace -UnregisteredOnly:$UnregisteredOnly

if ($features.Count -eq 0) {
    Write-Log "No features found matching criteria." "WARN"
    exit 0
}

# Display feature summary by state
Write-Host ""
Write-Host "Feature Summary by Registration State:" -ForegroundColor Cyan
$features | Group-Object RegistrationState | ForEach-Object {
    Write-Host "  $($_.Name): $($_.Count)" -ForegroundColor White
}
Write-Host ""

# Display features by provider
Write-Host "Features by Provider Namespace:" -ForegroundColor Cyan
$features | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 20 | ForEach-Object {
    Write-Host "  $($_.Name): $($_.Count)" -ForegroundColor White
}
if (($features | Group-Object ProviderName).Count -gt 20) {
    Write-Host "  ... and more" -ForegroundColor Gray
}
Write-Host ""

# List only mode
if ($ListOnly) {
    Write-Host "Features List (ListOnly mode):" -ForegroundColor Cyan
    Write-Host ""
    $features | Sort-Object ProviderName, FeatureName | Format-Table -Property @(
        @{Label = "Provider"; Expression = { $_.ProviderName } },
        @{Label = "Feature"; Expression = { $_.FeatureName } },
        @{Label = "State"; Expression = { $_.RegistrationState } }
    ) -AutoSize

    if ($ExportPath) {
        $features | Select-Object ProviderName, FeatureName, RegistrationState |
            Export-Csv -Path $ExportPath -NoTypeInformation
        Write-Log "Exported to: $ExportPath" "SUCCESS"
    }
    exit 0
}

# Filter to unregistered features for registration
$toRegister = $features | Where-Object {
    $_.RegistrationState -eq "Unregistered" -or
    $_.RegistrationState -eq "NotRegistered"
}

if ($toRegister.Count -eq 0) {
    Write-Log "No unregistered features to register." "INFO"
    exit 0
}

Write-Log "Found $($toRegister.Count) unregistered features to process" "INFO"
Write-Host ""

# Confirm registration
if (-not $Force -and -not $WhatIfPreference) {
    Write-Host "This will attempt to register $($toRegister.Count) preview features." -ForegroundColor Yellow
    Write-Host "Some features may require Microsoft approval (will show as 'Pending')." -ForegroundColor Yellow
    Write-Host "Some features do not support self-registration and will fail." -ForegroundColor Yellow
    Write-Host ""
    $confirm = Read-Host "Continue? (Y/N)"
    if ($confirm -ne "Y" -and $confirm -ne "y") {
        Write-Log "Operation cancelled by user." "WARN"
        exit 0
    }
}

# Register features
$results = @()
$registered = 0
$pending = 0
$unsupported = 0
$failed = 0

$total = $toRegister.Count
$current = 0

foreach ($feature in $toRegister) {
    $current++
    $progress = [math]::Round(($current / $total) * 100)
    Write-Progress -Activity "Registering Preview Features" -Status "$current of $total" -PercentComplete $progress

    $featureId = "$($feature.ProviderName)/$($feature.FeatureName)"

    if ($WhatIfPreference) {
        Write-Log "WhatIf: Would register $featureId" "INFO"
        $results += [PSCustomObject]@{
            ProviderNamespace = $feature.ProviderName
            FeatureName       = $feature.FeatureName
            PreviousState     = $feature.RegistrationState
            NewState          = "WhatIf"
            Success           = $true
            Error             = $null
        }
        continue
    }

    Write-Log "Registering: $featureId" "INFO"
    $result = Register-PreviewFeature -FeatureName $feature.FeatureName -ProviderNamespace $feature.ProviderName

    $results += [PSCustomObject]@{
        ProviderNamespace = $feature.ProviderName
        FeatureName       = $feature.FeatureName
        PreviousState     = $feature.RegistrationState
        NewState          = $result.State
        Success           = $result.Success
        Error             = $result.Error
    }

    switch ($result.State) {
        "Registered"   { $registered++; Write-Log "  -> Registered" "SUCCESS" }
        "Registering"  { $registered++; Write-Log "  -> Registering (in progress)" "SUCCESS" }
        "Pending"      { $pending++; Write-Log "  -> Pending (requires approval)" "WARN" }
        "Unsupported"  { $unsupported++; Write-Log "  -> Does not support self-registration" "WARN" }
        default        { $failed++; Write-Log "  -> Failed: $($result.Error)" "ERROR" }
    }

    # Small delay to avoid throttling
    Start-Sleep -Milliseconds 200
}

Write-Progress -Activity "Registering Preview Features" -Completed

# Summary
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "           Registration Summary         " -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Total Processed:    $total" -ForegroundColor White
Write-Host "  Registered:         $registered" -ForegroundColor Green
Write-Host "  Pending Approval:   $pending" -ForegroundColor Yellow
Write-Host "  Not Supported:      $unsupported" -ForegroundColor Yellow
Write-Host "  Failed:             $failed" -ForegroundColor Red
Write-Host ""

# Show pending features that need support request
$pendingFeatures = $results | Where-Object { $_.NewState -eq "Pending" }
if ($pendingFeatures.Count -gt 0) {
    Write-Host "Features Pending Approval (require Azure support request):" -ForegroundColor Yellow
    $pendingFeatures | ForEach-Object {
        Write-Host "  - $($_.ProviderNamespace)/$($_.FeatureName)" -ForegroundColor Yellow
    }
    Write-Host ""
}

# Show unsupported features
$unsupportedFeatures = $results | Where-Object { $_.NewState -eq "Unsupported" }
if ($unsupportedFeatures.Count -gt 0) {
    Write-Host "Features That Do Not Support Self-Registration:" -ForegroundColor Gray
    $unsupportedFeatures | Select-Object -First 10 | ForEach-Object {
        Write-Host "  - $($_.ProviderNamespace)/$($_.FeatureName)" -ForegroundColor Gray
    }
    if ($unsupportedFeatures.Count -gt 10) {
        Write-Host "  ... and $($unsupportedFeatures.Count - 10) more" -ForegroundColor Gray
    }
    Write-Host ""
}

# Export results
if ($ExportPath) {
    $results | Export-Csv -Path $ExportPath -NoTypeInformation
    Write-Log "Results exported to: $ExportPath" "SUCCESS"
}

# Reminder about provider registration
if ($registered -gt 0) {
    Write-Host ""
    Write-Host "NOTE: To propagate changes, run the following for each affected provider:" -ForegroundColor Cyan
    $affectedProviders = $results | Where-Object { $_.Success -and $_.NewState -match "Register" } |
        Select-Object -ExpandProperty ProviderNamespace -Unique
    foreach ($provider in $affectedProviders) {
        Write-Host "  Register-AzResourceProvider -ProviderNamespace $provider" -ForegroundColor White
    }
    Write-Host ""
}

Write-Log "Script completed." "INFO"
