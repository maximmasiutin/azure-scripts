# register-preview-features.ps1
# Registers/unregisters Azure preview features for a provider namespace
# Copyright 2023-2026 by Maxim Masiutin. All rights reserved.
#
# Features:
#   - Bulk registration: Registers all unregistered features in one run
#   - Single feature operations: Enable, disable, or check specific features
#   - Graceful error handling: Skips features that don't support self-registration
#   - Progress tracking: Shows registration status for each feature
#   - Export support: Save results to CSV for documentation
#
# Switches:
#   -ProviderNamespace  Filter to specific provider (e.g., "Microsoft.Compute")
#   -FeatureName        Target specific feature(s) by name (comma-separated or array)
#   -CheckStatus        Only check and display status of features
#   -Unregister         Unregister (disable) the specified feature(s)
#   -ListOnly           List features without registering
#   -UnregisteredOnly   Only show/process unregistered features
#   -Force              Skip confirmation prompt
#   -WhatIf             Show what would be registered/unregistered
#
# Examples:
#   pwsh register-preview-features.ps1 -ProviderNamespace "Microsoft.Compute" -Force
#   pwsh register-preview-features.ps1 -ListOnly
#   pwsh register-preview-features.ps1 -WhatIf
#   pwsh register-preview-features.ps1 -ProviderNamespace "Microsoft.Network" -FeatureName "AllowManaFastPath" -CheckStatus
#   pwsh register-preview-features.ps1 -ProviderNamespace "Microsoft.Network" -FeatureName "AllowManaFastPath" -Unregister
#   pwsh register-preview-features.ps1 -ProviderNamespace "Microsoft.Network" -FeatureName "AllowManaFastPath,EnableAcceleratedNetworking" -CheckStatus
#
# Requires: Azure PowerShell module (Az), Contributor/Owner role

<#
.SYNOPSIS
    Lists, registers, or unregisters Azure preview features across resource providers.

.DESCRIPTION
    This script discovers Azure preview features and can:
    - List all available features
    - Register unregistered features (bulk or specific)
    - Unregister (disable) specific features
    - Check status of specific features
    Some features require Microsoft approval and will show as "Pending".

.PARAMETER ProviderNamespace
    Optional. Filter to specific provider namespace (e.g., "Microsoft.Compute").
    Required when using -FeatureName.

.PARAMETER FeatureName
    Optional. Target specific feature(s) by name. Can be:
    - Single feature: "AllowManaFastPath"
    - Comma-separated: "AllowManaFastPath,EnableAcceleratedNetworking"
    - Array: @("Feature1", "Feature2")
    Requires -ProviderNamespace to be specified.

.PARAMETER CheckStatus
    Only check and display the registration status of features.
    Does not make any changes.

.PARAMETER Unregister
    Unregister (disable) the specified feature(s).
    Requires -ProviderNamespace and -FeatureName.

.PARAMETER ListOnly
    Only list available features without registering them.

.PARAMETER UnregisteredOnly
    Only show/process features that are not yet registered.

.PARAMETER ExportPath
    Path to export results as CSV file.

.PARAMETER WhatIf
    Show what would be registered/unregistered without actually doing it.

.EXAMPLE
    .\register-preview-features.ps1 -ListOnly
    Lists all available preview features.

.EXAMPLE
    .\register-preview-features.ps1 -ProviderNamespace "Microsoft.Compute"
    Registers all unregistered Microsoft.Compute preview features.

.EXAMPLE
    .\register-preview-features.ps1 -ProviderNamespace "Microsoft.Network" -FeatureName "AllowManaFastPath" -CheckStatus
    Checks the registration status of AllowManaFastPath feature.

.EXAMPLE
    .\register-preview-features.ps1 -ProviderNamespace "Microsoft.Network" -FeatureName "AllowManaFastPath" -Unregister
    Unregisters (disables) the AllowManaFastPath feature.

.EXAMPLE
    .\register-preview-features.ps1 -ProviderNamespace "Microsoft.Network" -FeatureName "AllowManaFastPath"
    Registers (enables) the AllowManaFastPath feature.

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

# PSScriptAnalyzer suppressions for Azure infrastructure script
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification='Interactive console script requires colored output')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification='Write-Log is a custom logging function')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Function returns collection of features')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string]$ProviderNamespace,

    [Parameter(Mandatory = $false)]
    [string[]]$FeatureName,

    [Parameter(Mandatory = $false)]
    [switch]$CheckStatus,

    [Parameter(Mandatory = $false)]
    [switch]$Unregister,

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

function Unregister-PreviewFeature {
    param(
        [string]$FeatureName,
        [string]$ProviderNamespace
    )

    try {
        $result = Unregister-AzProviderFeature -FeatureName $FeatureName -ProviderNamespace $ProviderNamespace
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
        if ($errorMsg -match "does not support unregistration" -or
            $errorMsg -match "FeatureUnregistrationUnsupported" -or
            $errorMsg -match "cannot be unregistered") {
            return @{
                FeatureName       = $FeatureName
                ProviderNamespace = $ProviderNamespace
                State             = "Unsupported"
                Success           = $false
                Error             = "Feature does not support unregistration"
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

function Get-FeatureStatus {
    param(
        [string]$FeatureName,
        [string]$ProviderNamespace
    )

    try {
        $feature = Get-AzProviderFeature -FeatureName $FeatureName -ProviderNamespace $ProviderNamespace -ErrorAction Stop
        return @{
            FeatureName       = $FeatureName
            ProviderNamespace = $ProviderNamespace
            State             = $feature.RegistrationState
            Success           = $true
            Error             = $null
        }
    }
    catch {
        return @{
            FeatureName       = $FeatureName
            ProviderNamespace = $ProviderNamespace
            State             = "NotFound"
            Success           = $false
            Error             = $_.Exception.Message
        }
    }
}

# Main script execution
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
if ($Unregister) {
    Write-Host "  Azure Preview Features Unregistration" -ForegroundColor Cyan
} elseif ($CheckStatus) {
    Write-Host "  Azure Preview Features Status Check  " -ForegroundColor Cyan
} else {
    Write-Host "  Azure Preview Features Registration  " -ForegroundColor Cyan
}
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Check Azure connection
if (-not (Test-AzureConnection)) {
    exit 1
}

# Parse FeatureName if provided as comma-separated string
if ($FeatureName -and $FeatureName.Count -eq 1 -and $FeatureName[0] -match ',') {
    $FeatureName = $FeatureName[0] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

# Handle specific feature operations (CheckStatus, Unregister, or single feature registration)
if ($FeatureName) {
    if (-not $ProviderNamespace) {
        Write-Log "ERROR: -ProviderNamespace is required when using -FeatureName" "ERROR"
        exit 1
    }

    $results = @()
    foreach ($fname in $FeatureName) {
        $featureId = "$ProviderNamespace/$fname"

        if ($CheckStatus) {
            Write-Log "Checking status: $featureId" "INFO"
            $result = Get-FeatureStatus -FeatureName $fname -ProviderNamespace $ProviderNamespace
            $results += [PSCustomObject]@{
                ProviderNamespace = $ProviderNamespace
                FeatureName       = $fname
                State             = $result.State
                Success           = $result.Success
                Error             = $result.Error
            }
            $stateColor = switch ($result.State) {
                "Registered"   { "Green" }
                "Registering"  { "Yellow" }
                "Unregistered" { "Gray" }
                "NotRegistered" { "Gray" }
                "Unregistering" { "Yellow" }
                "Pending"      { "Yellow" }
                "NotFound"     { "Red" }
                default        { "White" }
            }
            Write-Host "  $featureId : " -NoNewline -ForegroundColor White
            Write-Host "$($result.State)" -ForegroundColor $stateColor
            if ($result.Error) {
                Write-Host "    Error: $($result.Error)" -ForegroundColor Red
            }
        }
        elseif ($Unregister) {
            if ($WhatIfPreference) {
                Write-Log "WhatIf: Would unregister $featureId" "INFO"
                $results += [PSCustomObject]@{
                    ProviderNamespace = $ProviderNamespace
                    FeatureName       = $fname
                    State             = "WhatIf"
                    Success           = $true
                    Error             = $null
                }
            }
            else {
                # Check current status first
                $currentStatus = Get-FeatureStatus -FeatureName $fname -ProviderNamespace $ProviderNamespace
                if ($currentStatus.State -eq "Unregistered" -or $currentStatus.State -eq "NotRegistered") {
                    Write-Log "$featureId is already unregistered" "INFO"
                    $results += [PSCustomObject]@{
                        ProviderNamespace = $ProviderNamespace
                        FeatureName       = $fname
                        State             = $currentStatus.State
                        Success           = $true
                        Error             = "Already unregistered"
                    }
                    continue
                }

                Write-Log "Unregistering: $featureId" "INFO"
                $result = Unregister-PreviewFeature -FeatureName $fname -ProviderNamespace $ProviderNamespace
                $results += [PSCustomObject]@{
                    ProviderNamespace = $ProviderNamespace
                    FeatureName       = $fname
                    State             = $result.State
                    Success           = $result.Success
                    Error             = $result.Error
                }
                if ($result.Success) {
                    Write-Log "  -> $($result.State)" "SUCCESS"
                }
                else {
                    Write-Log "  -> Failed: $($result.Error)" "ERROR"
                }
            }
        }
        else {
            # Register specific feature
            if ($WhatIfPreference) {
                Write-Log "WhatIf: Would register $featureId" "INFO"
                $results += [PSCustomObject]@{
                    ProviderNamespace = $ProviderNamespace
                    FeatureName       = $fname
                    State             = "WhatIf"
                    Success           = $true
                    Error             = $null
                }
            }
            else {
                # Check current status first
                $currentStatus = Get-FeatureStatus -FeatureName $fname -ProviderNamespace $ProviderNamespace
                if ($currentStatus.State -eq "Registered") {
                    Write-Log "$featureId is already registered" "INFO"
                    $results += [PSCustomObject]@{
                        ProviderNamespace = $ProviderNamespace
                        FeatureName       = $fname
                        State             = $currentStatus.State
                        Success           = $true
                        Error             = "Already registered"
                    }
                    continue
                }

                Write-Log "Registering: $featureId" "INFO"
                $result = Register-PreviewFeature -FeatureName $fname -ProviderNamespace $ProviderNamespace
                $results += [PSCustomObject]@{
                    ProviderNamespace = $ProviderNamespace
                    FeatureName       = $fname
                    State             = $result.State
                    Success           = $result.Success
                    Error             = $result.Error
                }
                if ($result.Success) {
                    Write-Log "  -> $($result.State)" "SUCCESS"
                }
                else {
                    Write-Log "  -> Failed: $($result.Error)" "ERROR"
                }
            }
        }
    }

    # Summary for specific feature operations
    Write-Host ""
    Write-Host "Results:" -ForegroundColor Cyan
    $results | Format-Table -Property ProviderNamespace, FeatureName, State, Success -AutoSize

    if ($ExportPath) {
        $results | Export-Csv -Path $ExportPath -NoTypeInformation
        Write-Log "Results exported to: $ExportPath" "SUCCESS"
    }

    exit 0
}

# Bulk mode: Get all features
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
