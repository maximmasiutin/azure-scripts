# create-spot-vms.ps1
# Creates Azure Spot VMs with full ARM64 and latest Ubuntu support
# Copyright 2023-2025 by Maxim Masiutin. All rights reserved.
#
# Features:
#   - Full ARM64 support: ARM VMs (D*p*_v5, D*p*_v6) auto-detected
#   - Latest Ubuntu minimal: Auto-selects newest Ubuntu (25.10) with minimal image
#   - Architecture detection: Automatically uses ARM64 or x64 image based on VM size
#   - Spot pricing: Creates cost-effective spot instances with eviction handling
#
# Switches:
#   -UseLTS        Use LTS Ubuntu (24.04) instead of latest (25.10)
#   -PreferServer  Use full server image instead of minimal
#
# Examples:
#   pwsh create-spot-vms.ps1 -Location eastus -VMSize Standard_D4as_v5 -VMName myvm
#   pwsh create-spot-vms.ps1 -Location centralindia -VMSize Standard_D64pls_v6 -VMName arm-vm
#
# Requires: PowerShell 7.5 or later (run with pwsh)

# PSScriptAnalyzer suppressions for Azure infrastructure script
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification='Interactive console script requires colored output')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification='Parameters used in nested functions and splatting')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification='Password generated at runtime for VM provisioning')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification='Variables assigned for return values')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Function names match Azure conventions')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification='Write-Log is a custom logging function')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Functions perform Azure operations with built-in confirmation')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSupportsShouldProcess', '', Justification='WhatIf handled at script level')]
[CmdletBinding()]
param(
    # VM naming
    [int]$VMNumberFrom = 1,
    [int]$VMNumberTo = 1,
    [string]$VMNamePrefix = "vm",
    [string]$VMName,  # For single VM mode (overrides prefix/number)

    # Location and sizing
    [string]$Location = "eastus",
    [string]$VMSize = "Standard_D4as_v5",
    [string]$ResourceGroupName = "MyResourceGroup",

    # Network
    [string]$NetworkName = "MyNet",
    [string]$SubnetName = "MySubnet",
    [string]$SubnetAddressPrefix = "10.0.0.0/24",
    [string]$VnetAddressPrefix = "10.0.0.0/16",
    [switch]$NoPublicIP,
    [switch]$UseNatGateway,

    # Image - auto-detected based on CPU type if not specified
    [string]$ImagePublisher = "Canonical",
    [string]$ImageOffer,  # Auto-detected if not specified
    [string]$ImageSku,    # Auto-detected if not specified
    [string]$ImageVersion = "latest",
    [string]$StorageAccountType = "Standard_LRS",
    [string]$SecurityType = "TrustedLaunch",
    [switch]$UseLTS,      # Use LTS Ubuntu (24.04) instead of latest non-LTS (default: non-LTS)
    [switch]$PreferServer,  # Prefer server over minimal image

    # Authentication
    [string]$AdminUsername = "azureuser",
    [SecureString]$AdminPassword,
    [string]$SshPublicKey,

    # Key Vault (optional)
    [string]$KeyVaultName,
    [string]$KeyVaultResourceGroup,

    # Initialization
    [string]$CustomData,  # Cloud-init script content
    [string]$InitScriptUrl,  # URL to download and run via RunCommand
    [string]$InitScriptPath,  # Local script to run via RunCommand

    # Options
    [switch]$SkipQuotaCheck,
    [switch]$Force,
    [switch]$ForceOverwrite,  # Force resource overwrite without prompting
    [switch]$RequestQuota,  # Attempt to auto-request quota increase on failure
    [switch]$BlockSSH,      # If set, NSG will be created but SSH traffic blocked (default: allowed)
    [switch]$NoNSG,         # If set, skip NSG creation entirely (use with RemoveSSH in init script)
    [switch]$CleanupOrphans, # If set, delete orphaned Public IPs before VM creation
    [switch]$TrustedLaunchOnly  # If set, fail if TrustedLaunch not supported (no fallback to Standard)
)

# PowerShell version check
if ($PSVersionTable.PSVersion.Major -lt 7 -or
    ($PSVersionTable.PSVersion.Major -eq 7 -and $PSVersionTable.PSVersion.Minor -lt 5)) {
    Write-Host "ERROR: This script requires PowerShell 7.5 or later." -ForegroundColor Red
    Write-Host "Current version: $($PSVersionTable.PSVersion)" -ForegroundColor Red
    Write-Host "Please install PowerShell 7.5+ from https://github.com/PowerShell/PowerShell/releases" -ForegroundColor Yellow
    Write-Host "Run this script with: pwsh $($MyInvocation.MyCommand.Path)" -ForegroundColor Yellow
    exit 1
}

# Suppress Azure breaking change warnings to clean up logs
$env:SuppressAzurePowerShellBreakingChangeWarnings = "true"

# ==== HELPER FUNCTIONS ====

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "ERROR"   { "Red" }
        "WARN"    { "Yellow" }
        "SUCCESS" { "Green" }
        "DEBUG"   { "Gray" }
        default   { "White" }
    }
    Write-Host "[$Level] $timestamp - $Message" -ForegroundColor $color
}

function Test-IsArmVM {
    param([string]$VMSize)
    # ARM VMs have 'p' in the size after the series letter(s) and core count
    # Examples: D4ps_v5, D4pls_v6, D4pds_v5 (ARM Ampere Altra / Azure Cobalt 100)
    # Non-ARM: D4as_v5, D4s_v5, F4s_v2 (AMD/Intel)
    $size = $VMSize -replace "^Standard_", ""
    # Pattern: letter(s) + digits + 'p' + optional 'l/d' + 's' + '_v' + digit
    return $size -match "^[A-Za-z]+\d+p[lds]*_v\d+$"
}

function Get-LatestUbuntuImage {
    param(
        [string]$Location,
        [bool]$IsArm,
        [bool]$UseLTS = $false,
        [bool]$PreferServer = $false
    )

    # Ubuntu image offers in order of preference (newest first)
    # Non-LTS versions (default for spot VMs - latest features, stability less critical)
    $nonLtsOffers = @("ubuntu-25_10", "ubuntu-25_04", "ubuntu-24_10")
    # LTS versions (use with -UseLTS for production workloads)
    $ltsOffers = @("ubuntu-24_04-lts", "ubuntu-22_04-lts")

    # Default: prefer non-LTS (newest), fall back to LTS
    $offers = if ($UseLTS) { $ltsOffers + $nonLtsOffers } else { $nonLtsOffers + $ltsOffers }

    # SKU preferences based on architecture
    if ($IsArm) {
        $skuOrder = if ($PreferServer) {
            @("server-arm64", "minimal-arm64")
        } else {
            @("minimal-arm64", "server-arm64")
        }
    } else {
        # For x64, prefer gen2 (UEFI) over gen1 (BIOS)
        $skuOrder = if ($PreferServer) {
            @("server", "server-gen1", "minimal", "minimal-gen1")
        } else {
            @("minimal", "minimal-gen1", "server", "server-gen1")
        }
    }

    foreach ($offer in $offers) {
        try {
            $availableSkus = az vm image list-skus --publisher Canonical --offer $offer --location $Location --output json 2>$null | ConvertFrom-Json
            if ($availableSkus -and $availableSkus.Count -gt 0) {
                $skuNames = $availableSkus | ForEach-Object { $_.name }
                foreach ($sku in $skuOrder) {
                    if ($sku -in $skuNames) {
                        Write-Log "Found Ubuntu image: $offer / $sku" "SUCCESS"
                        return @{
                            Offer = $offer
                            Sku = $sku
                            IsMinimal = $sku -like "*minimal*"
                        }
                    }
                }
            }
        } catch {
            Write-Log "Could not query SKUs for $offer in $Location : $_" "DEBUG"
        }
    }

    # Fallback to old naming convention (Ubuntu 22.04)
    Write-Log "Falling back to Ubuntu 22.04 (old naming convention)" "WARN"
    if ($IsArm) {
        return @{
            Offer = "0001-com-ubuntu-server-jammy"
            Sku = "22_04-lts-arm64"
            IsMinimal = $false
        }
    } else {
        return @{
            Offer = "0001-com-ubuntu-server-jammy"
            Sku = "22_04-lts-gen2"
            IsMinimal = $false
        }
    }
}

function Get-VMFamilyName {
    param([string]$VMSize)
    # Extract short family name for quota API (e.g., D4pls_v5 -> DPLSv5)
    $size = $VMSize -replace "^Standard_", ""
    # Map patterns to family names (order matters - more specific patterns first)
    # See: https://learn.microsoft.com/en-us/azure/virtual-machines/vm-naming-conventions
    $patterns = [ordered]@{
        # ARM D-series v6 (Cobalt 100)
        "D.*plds_v6$" = "DPLDSv6"
        "D.*pls_v6$"  = "DPLSv6"
        "D.*pds_v6$"  = "DPDSv6"
        "D.*ps_v6$"   = "DPSv6"
        # ARM D-series v5 (Ampere Altra)
        "D.*plds_v5$" = "DPLDSv5"
        "D.*pls_v5$"  = "DPLSv5"
        "D.*pds_v5$"  = "DPDSv5"
        "D.*ps_v5$"   = "DPSv5"
        # AMD D-series v7 (Turin)
        "D.*alds_v7$" = "DALDSv7"
        "D.*als_v7$"  = "DALSv7"
        "D.*ads_v7$"  = "DADSv7"
        "D.*as_v7$"   = "DASv7"
        # AMD D-series v6 (Genoa)
        "D.*alds_v6$" = "DALDSv6"
        "D.*als_v6$"  = "DALSv6"
        "D.*ads_v6$"  = "DADSv6"
        "D.*as_v6$"   = "DASv6"
        # AMD D-series v5 (Milan)
        "D.*ads_v5$"  = "DADSv5"
        "D.*as_v5$"   = "DASv5"
        # Intel D-series v5 (Ice Lake)
        "D.*lds_v5$"  = "DLDSv5"
        "D.*ls_v5$"   = "DLSv5"
        "D.*ds_v5$"   = "DDSv5"
        "D.*s_v5$"    = "DSv5"
        "D.*d_v5$"    = "DDv5"
        "D.*_v5$"     = "Dv5"
        # AMD F-series v7 (Turin)
        "F.*amds_v7$" = "FAMDSv7"
        "F.*ams_v7$"  = "FAMSv7"
        "F.*alds_v7$" = "FALDSv7"
        "F.*als_v7$"  = "FALSv7"
        "F.*ads_v7$"  = "FADSv7"
        "F.*as_v7$"   = "FASv7"
        # AMD F-series v6 (Genoa)
        "F.*amds_v6$" = "FAMDSv6"
        "F.*ams_v6$"  = "FAMSv6"
        "F.*alds_v6$" = "FALDSv6"
        "F.*als_v6$"  = "FALSv6"
        "F.*ads_v6$"  = "FADSv6"
        "F.*as_v6$"   = "FASv6"
        # Intel F-series v2
        "F.*s_v2$"    = "FSv2"
        # ARM B-series v2
        "B.*pls_v2$"  = "BPLSv2"
        "B.*ps_v2$"   = "BPSv2"
        # Intel B-series v2
        "B.*ls_v2$"   = "BLSv2"
        "B.*s_v2$"    = "BSv2"
        # ARM E-series v5
        "E.*pds_v5$"  = "EPDSv5"
        "E.*ps_v5$"   = "EPSv5"
        # AMD E-series v5
        "E.*ads_v5$"  = "EADSv5"
        "E.*as_v5$"   = "EASv5"
        # Intel E-series v5
        "E.*ds_v5$"   = "EDSv5"
        "E.*s_v5$"    = "ESv5"
    }
    foreach ($pattern in $patterns.Keys) {
        if ($size -match $pattern) {
            return $patterns[$pattern]
        }
    }
    return $null
}

function Request-SpotQuotaIncrease {
    param(
        [string]$Location,
        [string]$VMFamily,
        [int]$RequestedLimit = 8
    )

    Write-Log "Requesting spot quota increase in $Location (limit: $RequestedLimit vCPUs)..." "INFO"

    try {
        # Get subscription and account info
        $context = Get-AzContext
        $subscriptionId = $context.Subscription.Id
        $accountName = $context.Account.Id

        # Generate unique ticket name
        $ticketName = "spot-quota-$Location-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

        # Azure Support API endpoint
        $apiVersions = @("2024-04-01", "2020-04-01")
        $result = $null

        foreach ($version in $apiVersions) {
            $supportUrl = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Support/supportTickets/${ticketName}?api-version=$version"

            try {
                # Submit support ticket
                $result = Invoke-RestMethod -Uri $supportUrl -Method Put -Headers $headers -Body $body -ErrorAction Stop
                break # Success
            } catch {
                $err = $_.Exception.Message
                if ($err -match "The api-version.*is not supported" -or $err -match "InvalidApiVersion") {
                    Write-Log "API version $version not supported in $Location, retrying with older version..." "WARN"
                    continue
                }
                throw $_ # Re-throw other errors
            }
        }

        if (-not $result) { throw "All API versions failed" }

        Write-Log "Support ticket created: $($result.name)" "SUCCESS"
        Write-Log "Status: $($result.properties.status)" "INFO"

        return @{
            Success = $true
            TicketName = $result.name
            TicketId = $result.properties.supportTicketId
            Status = $result.properties.status
        }
    }
    catch {
        $errorMsg = $_.Exception.Message
        Write-Log "Failed to create support ticket: $errorMsg" "ERROR"
        return @{
            Success = $false
            Error = $errorMsg
        }
    }
}

function Get-VMCoreCount {
    param([string]$VMSize)
    if ($VMSize -match "(\d+)") {
        return [int]$Matches[1]
    }
    return 4
}

function Get-VMCredentials {
    if ($KeyVaultName -and $KeyVaultResourceGroup) {
        try {
            $username = (Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "vmOsAdminUserName").SecretValueText
            $password = (Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "vmOsAdminPassword").SecretValue
            return @{ Credential = New-Object PSCredential($username, $password); Password = $null }
        } catch {
            Write-Log "Could not get credentials from Key Vault: $_" "WARN"
        }
    }

    $plaintextPassword = $null
    if (-not $AdminPassword) {
        # Cryptographically strong password generation
        # Length: 28
        # Alphabet: [a-zA-Z0-9-_] (64 characters)
        # 64 divides 256 evenly (256 = 64 * 4), so modulo 64 introduces NO bias.

        $length = 28
        $alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"

        # Generate random bytes
        $bytes = New-Object byte[] $length
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)

        # Map bytes to characters
        $generatedPwd = -join ($bytes | ForEach-Object { $alphabet[$_ % 64] })

        # Ensure Azure complexity (3 of 4: Upper, Lower, Digit, Special)
        # With length 28, statistical probability of missing a class is near zero,
        # but we check to be safe. If missing, we inject one of each at random positions.
        $hasUpper = $generatedPwd -cmatch "[A-Z]"
        $hasLower = $generatedPwd -cmatch "[a-z]"
        $hasDigit = $generatedPwd -match "[0-9]"
        $hasSpecial = $generatedPwd -match "[-_]"

        if (-not ($hasUpper -and $hasLower -and $hasDigit -and $hasSpecial)) {
            # Fallback: strict injection if RNG somehow missed a class (extremely unlikely)
            $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
            $b = New-Object byte[] 4
            $rng.GetBytes($b)

            # Convert string to char array to modify
            $chars = $generatedPwd.ToCharArray()

            # Inject missing classes at random indices
            if (-not $hasUpper)   { $chars[$b[0] % $length] = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"[$b[0] % 26] }
            if (-not $hasLower)   { $chars[$b[1] % $length] = "abcdefghijklmnopqrstuvwxyz"[$b[1] % 26] }
            if (-not $hasDigit)   { $chars[$b[2] % $length] = "0123456789"[$b[2] % 10] }
            if (-not $hasSpecial) { $chars[$b[3] % $length] = "-_"[$b[3] % 2] }

            $generatedPwd = -join $chars
        }

        $script:AdminPassword = ConvertTo-SecureString $generatedPwd -AsPlainText -Force
        $plaintextPassword = $generatedPwd
        Write-Log "Generated cryptographically strong admin password (28 chars)"
    }

    return @{ Credential = New-Object PSCredential($AdminUsername, $script:AdminPassword); Password = $plaintextPassword }
}

function Test-SpotQuota {
    param(
        [string]$Location,
        [string]$VMSize,
        [int]$RequiredCores = 4
    )

    Write-Log "Checking SPOT quota for $VMSize in $Location..."

    try {
        $usage = Get-AzVMUsage -Location $Location -ErrorAction Stop
        $coreCount = Get-VMCoreCount -VMSize $VMSize

        # Check lowPriorityCores (spot quota) - shared across all VM families
        $spotQuota = $usage | Where-Object { $_.Name.Value -eq "lowPriorityCores" }

        if ($spotQuota) {
            $available = $spotQuota.Limit - $spotQuota.CurrentValue
            Write-Log "Spot vCPU quota: $($spotQuota.CurrentValue)/$($spotQuota.Limit) (available: $available)"

            if ($available -ge $coreCount) {
                return @{
                    Success = $true
                    Available = $available
                    Required = $coreCount
                    Limit = $spotQuota.Limit
                    Family = "Total Regional Spot vCPUs"
                }
            } else {
                return @{
                    Success = $false
                    Available = $available
                    Required = $coreCount
                    Limit = $spotQuota.Limit
                    Family = "Total Regional Spot vCPUs"
                    Message = "Insufficient SPOT quota: need $coreCount cores, only $available available"
                }
            }
        } else {
            Write-Log "No spot quota entry found (lowPriorityCores)" "WARN"
            return @{
                Success = $false
                Available = 0
                Required = $coreCount
                Family = "Total Regional Spot vCPUs"
                Message = "No spot quota found in $Location"
            }
        }
    }
    catch {
        $errorMsg = $_.Exception.Message
        Write-Log "Error checking quota: $errorMsg" "ERROR"

        if ($errorMsg -match "NoRegisteredProviderFound|not.*supported.*location") {
            Write-Log "Region $Location does not support quota API - treating as unsupported" "WARN"
            return @{
                Success = $false
                Available = 0
                Required = $RequiredCores
                Family = "Unknown"
                Message = "Region $Location does not support quota API"
                UnsupportedRegion = $true
            }
        }

        return @{
            Success = $false
            Available = 0
            Required = $RequiredCores
            Family = "Unknown"
            Message = "Error checking quota: $errorMsg"
        }
    }
}

function Test-PublicIPQuota {
    param(
        [string]$Location,
        [int]$RequiredIPs = 1
    )

    Write-Log "Checking Public IP quota in $Location..."

    try {
        $usage = Get-AzNetworkUsage -Location $Location -ErrorAction Stop
        # Standard SKU Public IPs (what we use)
        $ipQuota = $usage | Where-Object { $_.Name.Value -eq "StandardPublicIPAddresses" }

        if ($ipQuota) {
            $available = $ipQuota.Limit - $ipQuota.CurrentValue
            Write-Log "Standard Public IP quota: $($ipQuota.CurrentValue)/$($ipQuota.Limit) (available: $available)"

            if ($available -ge $RequiredIPs) {
                return @{
                    Success = $true
                    Available = $available
                    Required = $RequiredIPs
                    Limit = $ipQuota.Limit
                    CurrentValue = $ipQuota.CurrentValue
                }
            } else {
                return @{
                    Success = $false
                    Available = $available
                    Required = $RequiredIPs
                    Limit = $ipQuota.Limit
                    CurrentValue = $ipQuota.CurrentValue
                    Message = "Insufficient Public IP quota: need $RequiredIPs, only $available available (limit: $($ipQuota.Limit))"
                }
            }
        } else {
            # No StandardPublicIPAddresses entry - this happens in some regions
            # We'll proceed and let the actual IP creation determine if it works
            Write-Log "No Standard Public IP quota entry found" "WARN"
            return @{
                Success = $true  # Assume OK if no quota entry (unlikely)
                Available = 999
                Required = $RequiredIPs
                Message = "No quota entry found, assuming OK"
                QuotaUnknown = $true
            }
        }
    }
    catch {
        $errorMsg = $_.Exception.Message
        Write-Log "Error checking Public IP quota: $errorMsg" "WARN"
        # Don't fail on quota check errors - let the actual creation fail if needed
        return @{
            Success = $true
            Available = 0
            Required = $RequiredIPs
            Message = "Could not check quota: $errorMsg"
            QuotaUnknown = $true
        }
    }
}

function Remove-OrphanedPublicIPs {
    param(
        [string]$ResourceGroupName,
        [switch]$WhatIf
    )

    Write-Log "Checking for orphaned Public IPs in $ResourceGroupName..."

    try {
        $allIPs = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -ErrorAction Stop
        $orphans = $allIPs | Where-Object { $null -eq $_.IpConfiguration }

        if ($orphans.Count -eq 0) {
            Write-Log "No orphaned Public IPs found"
            return 0
        }

        Write-Log "Found $($orphans.Count) orphaned Public IP(s)" "WARN"

        foreach ($ip in $orphans) {
            if ($WhatIf) {
                Write-Log "Would delete orphaned IP: $($ip.Name) ($($ip.IpAddress))" "WARN"
            } else {
                Write-Log "Deleting orphaned IP: $($ip.Name) ($($ip.IpAddress))" "WARN"
                Remove-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -Name $ip.Name -Force -ErrorAction Stop
            }
        }

        return $orphans.Count
    }
    catch {
        $errMsg = $_.Exception.Message
        if ($errMsg -match "ResourceGroupNotFound|was not found") {
            Write-Log "Resource group $ResourceGroupName not found, skipping orphan cleanup" "DEBUG"
            return 0
        }
        Write-Log "Error checking for orphaned IPs: $errMsg" "WARN"
        return 0
    }
}

function Request-PublicIPQuotaIncrease {
    param(
        [string]$Location,
        [int]$RequestedLimit = 50
    )

    Write-Log "Requesting Public IP quota increase in $Location (limit: $RequestedLimit)..." "INFO"

    try {
        $context = Get-AzContext
        $subscriptionId = $context.Subscription.Id

        # Register Microsoft.Quota provider if not registered
        $provider = Get-AzResourceProvider -ProviderNamespace Microsoft.Quota -ErrorAction SilentlyContinue
        if (-not $provider -or $provider.RegistrationState -ne "Registered") {
            Write-Log "Registering Microsoft.Quota provider..." "INFO"
            Register-AzResourceProvider -ProviderNamespace Microsoft.Quota | Out-Null
            Start-Sleep -Seconds 10
        }

        # Build the quota request payload
        $payload = @{
            properties = @{
                limit = @{ limitObjectType = "LimitValue"; value = $RequestedLimit }
                name = @{ value = "PublicIPAddresses" }
                resourceType = "PublicIpAddresses"
            }
        } | ConvertTo-Json -Depth 5

        # API endpoint for Public IP quota
        $apiVersion = "2023-02-01"
        $resourceName = "PublicIPAddresses"
        $path = "/subscriptions/$subscriptionId/providers/Microsoft.Network/locations/$Location/providers/Microsoft.Quota/quotas/${resourceName}?api-version=$apiVersion"

        Write-Log "Submitting quota request via REST API..." "DEBUG"
        $response = Invoke-AzRestMethod -Method PUT -Path $path -Payload $payload

        if ($response.StatusCode -eq 200 -or $response.StatusCode -eq 201 -or $response.StatusCode -eq 202) {
            $content = $response.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
            $state = if ($content.properties.provisioningState) { $content.properties.provisioningState } else { "Submitted" }
            Write-Log "Quota request submitted: $state" "SUCCESS"
            Write-Log "Check status in Azure Portal > Quotas > Networking" "INFO"
            return $true
        } else {
            Write-Log "Quota request failed: HTTP $($response.StatusCode)" "WARN"
            Write-Log "Response: $($response.Content)" "DEBUG"
            return $false
        }
    }
    catch {
        Write-Log "Error requesting quota increase: $($_.Exception.Message)" "WARN"
        Write-Log "Request quota manually via Azure Portal > Quotas > Networking" "INFO"
        return $false
    }
}

function Show-QuotaIncreaseInstructions {
    param(
        [string]$Location,
        [string]$Family,
        [int]$RequiredCores,
        [int]$QuotaLimit = 0
    )

    # Skip if quota limit is already at max (Azure requires wire transfer for >200)
    if ($QuotaLimit -ge 200) {
        Write-Log "Quota limit is $QuotaLimit (max for credit card billing) - skipping increase suggestion" "DEBUG"
        return
    }

    Write-Log "============================================" "WARN"
    Write-Log "QUOTA INCREASE REQUIRED" "WARN"
    Write-Log "============================================" "WARN"
    Write-Log "Location: $Location"
    Write-Log "Quota Type: Total Regional Spot vCPUs (lowPriorityCores)"
    Write-Log "Required Cores: $RequiredCores"
    Write-Log ""
    Write-Log "To request a quota increase:"
    Write-Log "1. Go to Azure Portal: https://portal.azure.com"
    Write-Log "2. Search for 'Quotas' in the search bar"
    Write-Log "3. Select 'Compute' under 'My quotas'"
    Write-Log "4. Filter by:"
    Write-Log "   - Region: $Location"
    Write-Log "   - Quota name: Total Regional Spot vCPUs"
    Write-Log "5. Click on the quota and select 'Request increase'"
    Write-Log "6. Enter the new limit (current + $RequiredCores or more)"
    Write-Log ""
    Write-Log "Direct link (may require login):"
    Write-Log "https://portal.azure.com/#view/Microsoft_Azure_Capacity/QuotaMenuBlade/~/myQuotas"
    Write-Log "============================================" "WARN"
}

# ==== MAIN ====

Write-Log "Starting Azure Spot VM creation"
Write-Log "Location: $Location, VM Size: $VMSize"
Write-Log "Resource Group: $ResourceGroupName"

# Determine VM names
if ($VMName) {
    $vmNames = @($VMName)
} else {
    $vmNames = ($VMNumberFrom..$VMNumberTo) | ForEach-Object { "$VMNamePrefix$_" }
}

Write-Log "VMs to create: $($vmNames -join ', ')"

# ==== ORPHAN CLEANUP ====
if ($CleanupOrphans) {
    $orphanCount = Remove-OrphanedPublicIPs -ResourceGroupName $ResourceGroupName
    if ($orphanCount -gt 0) {
        Write-Log "Cleaned up $orphanCount orphaned Public IP(s)" "SUCCESS"
    }
}

# ==== QUOTA CHECK ====
if (-not $SkipQuotaCheck) {
    $coreCount = Get-VMCoreCount -VMSize $VMSize
    $totalCores = $vmNames.Count * $coreCount
    $quotaResult = Test-SpotQuota -Location $Location -VMSize $VMSize -RequiredCores $totalCores

    if (-not $quotaResult.Success) {
        Write-Log "Quota check failed: $($quotaResult.Message)" "ERROR"

        if ($quotaResult.UnsupportedRegion) {
            Write-Log "Region $Location does not support quota API, will try VM creation anyway" "WARN"
        } elseif (-not $Force) {
            Show-QuotaIncreaseInstructions -Location $Location -Family $quotaResult.Family -RequiredCores $totalCores -QuotaLimit $quotaResult.Limit

            if ($RequestQuota) {
                Write-Log "RequestQuota switch is ON. Attempting automatic quota request..." "INFO"
                $family = Get-VMFamilyName -VMSize $VMSize
                if ($family) {
                    Request-SpotQuotaIncrease -Location $Location -VMFamily $family -RequestedLimit 8
                } else {
                    Write-Log "Could not determine VM family for quota request" "WARN"
                }
            } else {
                Write-Log "Use -RequestQuota to attempt automatic quota increase" "INFO"
            }

            Write-Log "Use -Force to attempt VM creation anyway, or -SkipQuotaCheck to skip this check" "WARN"
            return @{
                Success = $false
                QuotaError = $true
                Error = "Quota check failed: $($quotaResult.Message)"
                Location = $Location
                Family = $quotaResult.Family
            }
        } else {
            Write-Log "Force flag set, attempting VM creation despite quota warning..." "WARN"
        }
    } else {
        Write-Log "Quota check passed: $($quotaResult.Available) spot cores available"
    }

    # Check Public IP quota (only if we're creating public IPs)
    if (-not $NoPublicIP) {
        $ipQuotaResult = Test-PublicIPQuota -Location $Location -RequiredIPs $vmNames.Count

        if (-not $ipQuotaResult.Success) {
            Write-Log "Public IP quota check failed: $($ipQuotaResult.Message)" "ERROR"
            Write-Log "============================================" "WARN"
            Write-Log "PUBLIC IP QUOTA INCREASE REQUIRED" "WARN"
            Write-Log "============================================" "WARN"
            Write-Log "Location: $Location"
            Write-Log "Current usage: $($ipQuotaResult.CurrentValue)/$($ipQuotaResult.Limit)"
            Write-Log "Required: $($vmNames.Count) additional IPs"
            Write-Log ""
            Write-Log "Options:"
            Write-Log "1. Request quota increase via Azure Portal > Quotas > Networking"
            Write-Log "2. Use -NoPublicIP to skip public IP creation (requires NAT Gateway or jumpbox)"
            Write-Log "3. Use -NoPublicIP -UseNatGateway to use NAT Gateway for outbound traffic"
            Write-Log "============================================" "WARN"

            if ($RequestQuota) {
                Write-Log "RequestQuota switch is ON. Attempting automatic IP quota request..." "INFO"
                $newLimit = [Math]::Max(50, $ipQuotaResult.Limit + $vmNames.Count + 10)
                Request-PublicIPQuotaIncrease -Location $Location -RequestedLimit $newLimit
            } else {
                Write-Log "Use -RequestQuota to attempt automatic quota increase" "INFO"
            }

            if (-not $Force) {
                Write-Log "Use -Force to attempt VM creation anyway" "WARN"
                return @{
                    Success = $false
                    QuotaError = $true
                    Error = "Public IP quota check failed: $($ipQuotaResult.Message)"
                    Location = $Location
                }
            } else {
                Write-Log "Force flag set, attempting VM creation despite IP quota warning..." "WARN"
            }
        } else {
            if ($ipQuotaResult.QuotaUnknown) {
                Write-Log "Public IP quota check passed (quota entry not found, assuming no limit)"
            } else {
                Write-Log "Public IP quota check passed: $($ipQuotaResult.Available) IPs available"
            }
        }
    }
}

# ==== RESOURCE GROUP ====
Write-Log "Checking resource group..."
$rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue

if ($rg) {
    # Check if existing resource group is in the correct region
    $rgLocation = $rg.Location.ToLower() -replace '\s', ''
    $targetLocation = $Location.ToLower() -replace '\s', ''
    if ($rgLocation -ne $targetLocation) {
        Write-Log "Resource group exists in $($rg.Location) but target is $Location - deleting..." "WARN"
        try {
            Remove-AzResourceGroup -Name $ResourceGroupName -Force -ErrorAction Stop
            Write-Log "Deleted resource group, waiting for deletion to complete..."
            # Wait for deletion to propagate
            $deleteWait = 0
            $maxDeleteWait = 60
            while ($deleteWait -lt $maxDeleteWait) {
                Start-Sleep -Seconds 5
                $deleteWait += 5
                $checkRg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
                if (-not $checkRg) {
                    Write-Log "Resource group deletion confirmed"
                    break
                }
                Write-Log "Waiting for resource group deletion... ($deleteWait/$maxDeleteWait sec)" "DEBUG"
            }
            $rg = $null
        } catch {
            Write-Log "Error deleting resource group: $($_.Exception.Message)" "ERROR"
            return @{ Success = $false; Error = "Failed to delete Resource Group in wrong region: $($_.Exception.Message)" }
        }
    } else {
        Write-Log "Using existing resource group: $ResourceGroupName"
    }
}

if (-not $rg) {
    Write-Log "Creating resource group: $ResourceGroupName in $Location"
    try {
        $rgParams = @{
            Name = $ResourceGroupName
            Location = $Location
            ErrorAction = "Stop"
        }
        if ($ForceOverwrite) { $rgParams.Force = $true }
        $rg = New-AzResourceGroup @rgParams
        # Wait for resource group to fully propagate in Azure
        Write-Log "Waiting for resource group to propagate..."
        Start-Sleep -Seconds 20
    }
    catch {
        Write-Log "Error creating resource group '$ResourceGroupName': $($_.Exception.Message)" "ERROR"
        return @{ Success = $false; Error = "Failed to create Resource Group: $($_.Exception.Message)" }
    }
}

    # ==== VIRTUAL NETWORK ====
    Write-Log "Checking virtual network..."
    $vnet = Get-AzVirtualNetwork -Name $NetworkName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue

    if (-not $vnet) {
        Write-Log "Creating virtual network: $NetworkName"
        $vnetCreated = $false
        $vnetAttempt = 0
        $maxVnetAttempts = 12
        while (-not $vnetCreated -and $vnetAttempt -lt $maxVnetAttempts) {
            $vnetAttempt++
            try {
                $subnetConfig = New-AzVirtualNetworkSubnetConfig -Name $SubnetName -AddressPrefix $SubnetAddressPrefix
                $vnetParams = @{
                    Name = $NetworkName
                    ResourceGroupName = $ResourceGroupName
                    Location = $Location
                    AddressPrefix = $VnetAddressPrefix
                    Subnet = $subnetConfig
                    ErrorAction = "Stop"
                }
                if ($ForceOverwrite) { $vnetParams.Force = $true }
                $vnet = New-AzVirtualNetwork @vnetParams
                $vnetCreated = $true
                # Wait for VNet to fully propagate
                Write-Log "Waiting for VNet to propagate..."
                Start-Sleep -Seconds 5
            } catch {
                $errorMsg = $_.Exception.Message

                if ($errorMsg -match "LocationNotAvailableForResourceType|not available for resource type") {
                    Write-Log "Region $Location does not support virtual networks - restricted region" "ERROR"
                    return @{
                        Success = $false
                        UnsupportedRegion = $true
                        Error = "Region $Location does not support virtual networks"
                        Location = $Location
                    }
                }

                # ResourceNotFound means resource group not fully propagated yet
                if ($errorMsg -match "ResourceNotFound|was not found") {
                    if ($vnetAttempt -lt $maxVnetAttempts) {
                        $waitSecs = 15
                        Write-Log "Resource group not ready (attempt $vnetAttempt/$maxVnetAttempts), waiting ${waitSecs}s..." "WARN"
                        Start-Sleep -Seconds $waitSecs
                    } else {
                        Write-Log "Error creating virtual network after $maxVnetAttempts attempts: $errorMsg" "ERROR"
                        throw
                    }
                } else {
                    Write-Log "Error creating virtual network: $errorMsg" "ERROR"
                    throw
                }
            }
        }
    } else {
    Write-Log "Using existing virtual network: $NetworkName"
}

# Get subnet ID
try {
    $subnetId = ($vnet.Subnets | Where-Object { $_.Name -eq $SubnetName }).Id
    if (-not $subnetId) {
        if ($vnet.Subnets.Count -gt 0) {
            $subnetId = $vnet.Subnets[0].Id
            Write-Log "Using first available subnet: $($vnet.Subnets[0].Name)" "DEBUG"
        } else {
            Write-Log "No subnets found, creating: $SubnetName"
            $subnetConfig = Add-AzVirtualNetworkSubnetConfig -Name $SubnetName -VirtualNetwork $vnet -AddressPrefix $SubnetAddressPrefix -ErrorAction Stop

            # Use Set-AzVirtualNetwork with error handling
            $vnet = $vnet | Set-AzVirtualNetwork -ErrorAction Stop

            # Refresh VNet object to get new subnet ID
            $vnet = Get-AzVirtualNetwork -Name $NetworkName -ResourceGroupName $ResourceGroupName -ErrorAction Stop
            $subnetId = ($vnet.Subnets | Where-Object { $_.Name -eq $SubnetName }).Id

            if (-not $subnetId) {
                 throw "Subnet creation appeared successful but subnet ID is null"
            }
        }
    }
} catch {
    Write-Log "Error configuring subnet: $($_.Exception.Message)" "ERROR"
    return @{ Success = $false; Error = "Failed to configure subnet: $($_.Exception.Message)" }
}

# ==== NAT GATEWAY (if requested) ====
    if ($NoPublicIP -and $UseNatGateway) {
        $natGwName = "$NetworkName-natgw"
        $natGw = Get-AzNatGateway -ResourceGroupName $ResourceGroupName -Name $natGwName -ErrorAction SilentlyContinue

        if (-not $natGw) {
            try {
                Write-Log "Creating NAT Gateway: $natGwName"

                $pipParams = @{
                    Name = "$natGwName-pip"
                    ResourceGroupName = $ResourceGroupName
                    Location = $Location
                    AllocationMethod = "Static"
                    Sku = "Standard"
                    ErrorAction = "Stop"
                }
                if ($ForceOverwrite) { $pipParams.Force = $true }
                $natPip = New-AzPublicIpAddress @pipParams

                $natGwParams = @{
                    ResourceGroupName = $ResourceGroupName
                    Name = $natGwName
                    Location = $Location
                    PublicIpAddress = $natPip
                    Sku = "Standard"
                    IdleTimeoutInMinutes = 10
                    ErrorAction = "Stop"
                }
                if ($ForceOverwrite) { $natGwParams.Force = $true }
                $natGw = New-AzNatGateway @natGwParams

                $subnet = Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $vnet -Name $SubnetName
                Set-AzVirtualNetworkSubnetConfig -VirtualNetwork $vnet -Name $SubnetName -AddressPrefix $subnet.AddressPrefix -NatGateway $natGw | Out-Null
                $vnet | Set-AzVirtualNetwork | Out-Null
                Write-Log "NAT Gateway created and associated with subnet" "SUCCESS"
            } catch {
                Write-Log "Error creating/configuring NAT Gateway: $($_.Exception.Message)" "ERROR"
                # Don't fail the whole script, but warn
            }
        } else {
            Write-Log "Using existing NAT Gateway: $natGwName"
        }
    } elseif ($NoPublicIP) {
    Write-Log "WARNING: No public IP and no NAT Gateway - VM will have no outbound internet!" "WARN"
} else {
    Write-Log "Skipping NAT Gateway creation (UseNatGateway not specified)" "INFO"
}

# ==== CREDENTIALS ====
$credData = Get-VMCredentials
$credential = $credData.Credential
$generatedPassword = $credData.Password

# ==== CREATE VMs ====
$results = @()
foreach ($vmN in $vmNames) {
    Write-Log "Creating VM: $vmN"

    # NIC
    $nicName = "$vmN-nic"
    $nicParams = @{
        Name = $nicName
        ResourceGroupName = $ResourceGroupName
        Location = $Location
        SubnetId = $subnetId
        ErrorAction = "Stop"
    }
    if ($ForceOverwrite) { $nicParams.Force = $true }

    # Check if VM size supports accelerated networking
    $supportedPrefixes = @("Standard_D", "Standard_E", "Standard_F", "Standard_L", "Standard_M")
    $supportsAccelNet = $false
    foreach ($prefix in $supportedPrefixes) {
        if ($VMSize -like "$prefix*") {
            $supportsAccelNet = $true
            break
        }
    }
    if ($supportsAccelNet) {
        $nicParams.EnableAcceleratedNetworking = $true
    }

    # Public IP (with smart retry for Azure propagation delays)
    # Error handling strategy:
    #   - QuotaExceeded/Limit: STOP immediately (quota is hard cap, waiting won't help)
    #   - ResourceGroupNotFound: Wait 30s and retry (propagation issue)
    #   - ResourceNotFound during creation: Likely quota, stop retrying
    #   - Network/timeout: Retry with 15s delay
    $pipName = $null
    $nsg = $null
    if (-not $NoPublicIP) {
        $pipName = "$vmN-pip"
        $pip = $null
        $pipRetries = 3
        $shouldStopRetrying = $false
        for ($pipAttempt = 1; $pipAttempt -le $pipRetries; $pipAttempt++) {
            try {
                $pipParams = @{
                    Name = $pipName
                    ResourceGroupName = $ResourceGroupName
                    Location = $Location
                    AllocationMethod = "Static"
                    Sku = "Standard"
                    ErrorAction = "Stop"
                }
                if ($ForceOverwrite) { $pipParams.Force = $true }
                $pip = New-AzPublicIpAddress @pipParams
                $nicParams.PublicIpAddressId = $pip.Id
                Write-Log "Created public IP: $pipName"
                break
            } catch {
                $errMsg = $_.Exception.Message

                # Quota errors - stop immediately, no point retrying
                if ($errMsg -match "QuotaExceeded|limit|exceeded|PublicIPAddressCountLimitReached") {
                    Write-Log "Public IP quota limit reached - stopping retries" "ERROR"
                    Write-Log "Request quota increase or use -NoPublicIP -UseNatGateway" "WARN"
                    $results += @{ VMName = $vmN; Success = $false; Error = "Public IP quota exceeded"; QuotaError = $true }
                    $shouldStopRetrying = $true
                    break
                }
                # ResourceNotFound during creation often means quota exhaustion (masked error)
                elseif ($errMsg -match "ResourceNotFound" -and $errMsg -notmatch "ResourceGroupNotFound") {
                    Write-Log "ResourceNotFound during IP creation - likely quota exhaustion" "ERROR"
                    $results += @{ VMName = $vmN; Success = $false; Error = "IP creation failed (likely quota)"; QuotaError = $true }
                    $shouldStopRetrying = $true
                    break
                }
                # ResourceGroupNotFound - propagation issue, wait longer
                elseif ($errMsg -match "ResourceGroupNotFound") {
                    if ($pipAttempt -lt $pipRetries) {
                        Write-Log "Resource group not propagated (attempt $pipAttempt/$pipRetries), waiting 30s..." "WARN"
                        Start-Sleep -Seconds 30
                    } else {
                        Write-Log "Error creating Public IP '$pipName': $errMsg" "ERROR"
                        $results += @{ VMName = $vmN; Success = $false; Error = "Failed to create Public IP: $errMsg" }
                    }
                }
                # Other errors - normal retry with 15s delay
                else {
                    if ($pipAttempt -lt $pipRetries) {
                        Write-Log "Public IP creation failed (attempt $pipAttempt/$pipRetries): $errMsg" "WARN"
                        Write-Log "Waiting 15s before retry..." "WARN"
                        Start-Sleep -Seconds 15
                    } else {
                        Write-Log "Error creating Public IP '$pipName': $errMsg" "ERROR"
                        $results += @{ VMName = $vmN; Success = $false; Error = "Failed to create Public IP: $errMsg" }
                    }
                }
            }
        }
        if ($shouldStopRetrying -or (-not $pip)) { continue }

        # Create NSG (unless -NoNSG is specified)
        if (-not $NoNSG) {
            $nsgName = "$vmN-nsg"
            $nsg = Get-AzNetworkSecurityGroup -Name $nsgName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue

            if (-not $nsg) {
                try {
                    $nsgParams = @{
                        ResourceGroupName = $ResourceGroupName
                        Location = $Location
                        Name = $nsgName
                        ErrorAction = "Stop"
                    }
                    if ($ForceOverwrite) { $nsgParams.Force = $true }

                    if ($BlockSSH) {
                        Write-Log "Creating NSG: $nsgName (SSH BLOCKED)"
                        $nsg = New-AzNetworkSecurityGroup @nsgParams
                    } else {
                        Write-Log "Creating NSG: $nsgName (SSH ALLOWED)"
                        $ruleSSH = New-AzNetworkSecurityRuleConfig -Name "AllowSSH" -Description "Allow SSH" `
                            -Access Allow -Protocol Tcp -Direction Inbound -Priority 1000 `
                            -SourceAddressPrefix Internet -SourcePortRange * `
                            -DestinationAddressPrefix * -DestinationPortRange 22
                        $nsg = New-AzNetworkSecurityGroup @nsgParams -SecurityRules $ruleSSH
                    }
                } catch {
                     Write-Log "Error creating NSG '$nsgName': $($_.Exception.Message)" "ERROR"
                     $results += @{ VMName = $vmN; Success = $false; Error = "Failed to create NSG: $($_.Exception.Message)" }
                     continue
                }
            } else {
                Write-Log "Using existing NSG: $nsgName"
            }
            $nicParams.NetworkSecurityGroupId = $nsg.Id
        } else {
            Write-Log "Skipping NSG creation (NoNSG specified)" "INFO"
        }
    } else {
        Write-Log "Skipping public IP creation (NoPublicIP specified)" "INFO"
    }

    # Wait for all network resources to propagate before creating NIC
    Write-Log "Waiting for network resources to propagate..."
    Start-Sleep -Seconds 5

    # Create NIC with retry logic for propagation issues
    $nic = $null
    $nicRetries = 3
    for ($nicRetry = 1; $nicRetry -le $nicRetries; $nicRetry++) {
        try {
            $nic = New-AzNetworkInterface @nicParams
            break
        } catch {
            $errMsg = $_.Exception.Message
            if ($nicRetry -lt $nicRetries -and $errMsg -match "NotFound|not found") {
                Write-Log "NIC creation failed with propagation error, retry $nicRetry/$nicRetries..." "WARN"
                Start-Sleep -Seconds 10
            } else {
                Write-Log "Error creating NIC '$nicName': $errMsg" "ERROR"
                $results += @{ VMName = $vmN; Success = $false; Error = "Failed to create NIC: $errMsg" }
                $nic = $null
                break
            }
        }
    }
    if (-not $nic) { continue }

    try {
        # VM Config
        $vmConfig = New-AzVMConfig -VMName $vmN -VMSize $VMSize -Priority "Spot" -EvictionPolicy "Delete" -MaxPrice -1

        # Auto-detect Ubuntu image based on VM type (ARM vs x64) and user preferences
        $actualImageOffer = $ImageOffer
        $actualImageSku = $ImageSku
        $isArm = Test-IsArmVM -VMSize $VMSize

        # TrustedLaunch is not supported on ARM VMs (D*p*_v5, D*p*_v6, E*p*_v5, etc.)
        # Must explicitly set "Standard" for ARM - skipping the call lets image default (TrustedLaunch) apply
        if ($isArm) {
            Write-Log "Setting Standard security type for ARM VM: $VMSize" "DEBUG"
            $vmConfig = Set-AzVMSecurityProfile -VM $vmConfig -SecurityType "Standard"
        } elseif ($SecurityType) {
            $vmConfig = Set-AzVMSecurityProfile -VM $vmConfig -SecurityType $SecurityType
        }

        if (-not $ImageOffer -or -not $ImageSku) {
            # Auto-detect best Ubuntu image for this VM type and location
            Write-Log "Auto-detecting Ubuntu image for $VMSize in $Location..."
            $imageInfo = Get-LatestUbuntuImage -Location $Location -IsArm $isArm -UseLTS $UseLTS -PreferServer $PreferServer
            $actualImageOffer = $imageInfo.Offer
            $actualImageSku = $imageInfo.Sku
            Write-Log "Using Ubuntu: $actualImageOffer / $actualImageSku (minimal: $($imageInfo.IsMinimal))" "INFO"
        } elseif ($isArm -and $actualImageSku -notlike "*arm64*") {
            # User specified image but it is not ARM64 - warn and try to fix
            Write-Log "ARM VM detected but non-ARM64 SKU specified: $actualImageSku" "WARN"
            if ($actualImageSku -eq "22_04-lts-gen2") {
                $actualImageSku = "22_04-lts-arm64"
                Write-Log "Auto-corrected SKU to: $actualImageSku" "INFO"
            }
        }

        $vmConfig = Set-AzVMSourceImage -VM $vmConfig -PublisherName $ImagePublisher -Offer $actualImageOffer -Skus $actualImageSku -Version $ImageVersion
        $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id -DeleteOption "Delete"
            $vmConfig = Set-AzVMOSDisk -VM $vmConfig -Name "$vmN-osdisk" -DeleteOption "Delete" -Linux -StorageAccountType $StorageAccountType -CreateOption "FromImage"
            $vmConfig = Set-AzVMBootDiagnostic -VM $vmConfig -Enable

            if ($SshPublicKey) {            $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Linux -ComputerName $vmN -Credential $credential -DisablePasswordAuthentication
            $vmConfig = Add-AzVMSshPublicKey -VM $vmConfig -KeyData $SshPublicKey -Path "/home/$AdminUsername/.ssh/authorized_keys"
        } else {
            $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Linux -ComputerName $vmN -Credential $credential
        }

        # Custom data (cloud-init)
        if ($CustomData) {
            $encodedData = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($CustomData))
            $vmConfig.OSProfile.CustomData = $encodedData
            Write-Log "Added cloud-init custom data"
        }
    } catch {
         Write-Log "Error constructing VM config for '$vmN': $($_.Exception.Message)" "ERROR"
         $results += @{ VMName = $vmN; Success = $false; Error = "Failed to construct VM configuration: $($_.Exception.Message)" }
         continue
    }

    # Clean up orphaned OS disk from previous failed creation (prevents securityProfile conflict)
    $osDiskName = "$vmN-osdisk"
    $existingDisk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $osDiskName -ErrorAction SilentlyContinue
    if ($existingDisk) {
        Write-Log "Deleting orphaned OS disk: $osDiskName (prevents security type conflict)" "WARN"
        Remove-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $osDiskName -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 5
    }

    # Create VM
    try {
        $vmParams = @{
            ResourceGroupName = $ResourceGroupName
            Location = $Location
            VM = $vmConfig
            Verbose = $true
            ErrorAction = "Stop"
        }
        # New-AzVM does not support -Force

        $vm = New-AzVM @vmParams
        Write-Log "VM created: $vmN" "SUCCESS"

        # Run init script via URL (if provided)
        if ($InitScriptUrl) {
            try {
                $initCmd = "cd /tmp && wget -q '$InitScriptUrl' -O init.bash && chmod +x init.bash && ./init.bash > /var/log/init.log 2>&1"
                Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmN -CommandId 'RunShellScript' -ScriptString $initCmd -AsJob -ErrorAction Stop
                Write-Log "Init script (URL) started as background job"
            } catch {
                Write-Log "Failed to start init script (URL) job: $($_.Exception.Message)" "WARN"
            }
        }

        # Run local init script via RunCommand (if provided and no cloud-init)
        if ($InitScriptPath -and (Test-Path $InitScriptPath) -and -not $CustomData) {
            try {
                $scriptContent = Get-Content $InitScriptPath -Raw
                Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmN -CommandId 'RunShellScript' -ScriptString $scriptContent -AsJob -ErrorAction Stop
                Write-Log "Init script (local) started as background job"
            } catch {
                Write-Log "Failed to start init script (local) job: $($_.Exception.Message)" "WARN"
            }
        }

        # Get public IP
        $publicIp = $null
        if (-not $NoPublicIP -and $pipName) {
            try {
                $publicIpObj = Get-AzPublicIpAddress -Name $pipName -ResourceGroupName $ResourceGroupName -ErrorAction Stop
                $publicIp = $publicIpObj.IpAddress
                if ($publicIp) {
                    Write-Log "Public IP: $publicIp"
                    Write-Log "SSH: ssh $AdminUsername@$publicIp"
                } else {
                     Write-Log "Public IP resource created but no IP address assigned yet." "WARN"
                }
            } catch {
                 Write-Log "Failed to retrieve Public IP address: $($_.Exception.Message)" "WARN"
            }
        }

        $results += @{
            VMName = $vmN
            Success = $true
            PublicIP = $publicIp
            Location = $Location
            VMSize = $VMSize
            ImageOffer = $actualImageOffer
            ImageSku = $actualImageSku
            AdminPassword = $generatedPassword
        }
    } catch {
        $errorMsg = $_.Exception.Message
        Write-Log "Failed to create $vmN : $errorMsg" "ERROR"

        $resultEntry = @{
            VMName = $vmN
            Success = $false
            Error = $errorMsg
            Location = $Location
            VMSize = $VMSize
        }

        # Check if quota error
        if ($errorMsg -match "quota|QuotaExceeded|OperationNotAllowed|exceeding") {
            $resultEntry.QuotaError = $true
            $familyInfo = Get-VMFamilyName -VMSize $VMSize
            $resultEntry.Family = $familyInfo
            # Pass 200 as default limit - quota increase not possible without wire transfer
            Show-QuotaIncreaseInstructions -Location $Location -Family $familyInfo -RequiredCores (Get-VMCoreCount -VMSize $VMSize) -QuotaLimit 200

            if ($RequestQuota) {
                Write-Log "RequestQuota switch is ON. Attempting automatic quota request..." "INFO"
                if ($familyInfo) {
                    Request-SpotQuotaIncrease -Location $Location -VMFamily $familyInfo -RequestedLimit 8
                }
            }
        }

        # Check if unsupported region
        if ($errorMsg -match "LocationNotAvailableForResourceType|not available for resource type|NoRegisteredProviderFound") {
            $resultEntry.UnsupportedRegion = $true
        }

        # Check if FastPath/accelerated networking error (region-specific network limitation)
        # FastPath is MANA (Microsoft Azure Network Adapter) preview feature on v6 series VMs
        # Some regions/VM sizes have issues with MANA FastPath - retry with AcceleratedNetworking disabled
        if ($errorMsg -match "FastPathDoesNotSupportApplicationGatewayDeployment|FastPath.*not support") {
            Write-Log "FastPath networking error detected in region $Location for VM size $VMSize" "WARN"
            Write-Log "This is likely a MANA (Microsoft Azure Network Adapter) preview limitation" "WARN"
            Write-Log "Azure error: FastPathDoesNotSupportApplicationGatewayDeployment (despite no AppGateway)" "WARN"
            Write-Log "Retrying with Accelerated Networking disabled..." "WARN"

            try {
                # Delete orphaned resources from failed attempt
                $existingDisk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName "$vmN-osdisk" -ErrorAction SilentlyContinue
                if ($existingDisk) {
                    Write-Log "Deleting orphaned OS disk: $vmN-osdisk" "WARN"
                    Remove-AzDisk -ResourceGroupName $ResourceGroupName -DiskName "$vmN-osdisk" -Force -ErrorAction SilentlyContinue
                }

                # Delete the existing NIC (which has AcceleratedNetworking enabled)
                $existingNic = Get-AzNetworkInterface -Name "$vmN-nic" -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
                if ($existingNic) {
                    Write-Log "Deleting NIC with AcceleratedNetworking: $vmN-nic" "WARN"
                    Remove-AzNetworkInterface -Name "$vmN-nic" -ResourceGroupName $ResourceGroupName -Force -ErrorAction SilentlyContinue
                }

                Start-Sleep -Seconds 5

                # Create new NIC WITHOUT accelerated networking
                Write-Log "Creating new NIC without AcceleratedNetworking..." "INFO"

                # Re-fetch VNet and subnet (may be out of scope in error handler)
                # VNet might have been deleted or not found after failed VM creation
                $vnetRetry = Get-AzVirtualNetwork -Name $NetworkName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
                if (-not $vnetRetry) {
                    Write-Log "VNet not found, recreating: $NetworkName" "WARN"
                    $vnetRetry = New-AzVirtualNetwork -Name $NetworkName -ResourceGroupName $ResourceGroupName -Location $Location -AddressPrefix "10.0.0.0/16" -ErrorAction Stop
                    $subnetConfig = Add-AzVirtualNetworkSubnetConfig -Name $SubnetName -AddressPrefix "10.0.0.0/24" -VirtualNetwork $vnetRetry
                    $vnetRetry = Set-AzVirtualNetwork -VirtualNetwork $vnetRetry
                    Write-Log "VNet recreated: $NetworkName" "SUCCESS"
                    Start-Sleep -Seconds 5  # Wait for VNet to propagate
                }
                $subnetRetry = Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $vnetRetry -Name $SubnetName -ErrorAction Stop

                $nicRetryParams = @{
                    Name = "$vmN-nic"
                    ResourceGroupName = $ResourceGroupName
                    Location = $Location
                    SubnetId = $subnetRetry.Id
                    ErrorAction = "Stop"
                }
                # Explicitly do NOT set EnableAcceleratedNetworking
                if ($pipName -and -not $NoPublicIP) {
                    $pipRetry = Get-AzPublicIpAddress -Name $pipName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
                    if (-not $pipRetry) {
                        Write-Log "Public IP not found, recreating: $pipName" "WARN"
                        $pipRetry = New-AzPublicIpAddress -Name $pipName -ResourceGroupName $ResourceGroupName -Location $Location -AllocationMethod Static -Sku Standard -ErrorAction Stop
                        Write-Log "Public IP recreated: $pipName" "SUCCESS"
                    }
                    if ($pipRetry) {
                        $nicRetryParams.PublicIpAddressId = $pipRetry.Id
                    }
                }
                if ($nsg) {
                    $nicRetryParams.NetworkSecurityGroupId = $nsg.Id
                }
                $nicRetry = New-AzNetworkInterface @nicRetryParams
                Write-Log "Created NIC without AcceleratedNetworking: $vmN-nic" "SUCCESS"

                # Rebuild VM config with new NIC
                $vmConfigRetry = New-AzVMConfig -VMName $vmN -VMSize $VMSize -Priority "Spot" -EvictionPolicy "Delete" -MaxPrice -1
                if (-not $isArm) {
                    $vmConfigRetry = Set-AzVMSecurityProfile -VM $vmConfigRetry -SecurityType $SecurityType
                }
                $vmConfigRetry = Set-AzVMSourceImage -VM $vmConfigRetry -PublisherName $ImagePublisher -Offer $actualImageOffer -Skus $actualImageSku -Version $ImageVersion
                $vmConfigRetry = Add-AzVMNetworkInterface -VM $vmConfigRetry -Id $nicRetry.Id -DeleteOption "Delete"
                $vmConfigRetry = Set-AzVMOSDisk -VM $vmConfigRetry -Name "$vmN-osdisk" -DeleteOption "Delete" -Linux -StorageAccountType $StorageAccountType -CreateOption "FromImage"
                $vmConfigRetry = Set-AzVMBootDiagnostic -VM $vmConfigRetry -Enable
                $vmConfigRetry = Set-AzVMOperatingSystem -VM $vmConfigRetry -Linux -ComputerName $vmN -Credential $credential
                if ($CustomData) {
                    $encodedData = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($CustomData))
                    $vmConfigRetry.OSProfile.CustomData = $encodedData
                }

                $vmRetryParams = @{
                    ResourceGroupName = $ResourceGroupName
                    Location = $Location
                    VM = $vmConfigRetry
                    Verbose = $true
                    ErrorAction = "Stop"
                }
                $vm = New-AzVM @vmRetryParams
                Write-Log "VM created on retry without AcceleratedNetworking: $vmN" "SUCCESS"

                # Get public IP for the successfully created VM
                if (-not $NoPublicIP -and $pipName) {
                    try {
                        $publicIpObj = Get-AzPublicIpAddress -Name $pipName -ResourceGroupName $ResourceGroupName -ErrorAction Stop
                        $resultEntry.PublicIP = $publicIpObj.IpAddress
                        Write-Log "Public IP: $($resultEntry.PublicIP)"
                    } catch {
                        Write-Log "Failed to retrieve Public IP: $($_.Exception.Message)" "WARN"
                    }
                }

                # Update result entry to success
                $resultEntry.Success = $true
                $resultEntry.Remove('Error')
                $resultEntry.FastPathRetry = $true
                $resultEntry.AcceleratedNetworkingDisabled = $true
                $resultEntry.AdminPassword = $generatedPassword
            } catch {
                $retryError = $_.Exception.Message
                Write-Log "Retry without AcceleratedNetworking also failed: $retryError" "ERROR"
                $resultEntry.RetryError = $retryError
                $resultEntry.Error = $retryError  # Update error to retry error for proper handling
                # Don't set FastPathError here - the retry error might be unrelated to FastPath
                # Let the orchestrator handle the new error appropriately
            }
        }

        # Check if VM size requires feature flag registration (preview/restricted SKUs)
        if ($errorMsg -match "not available to the current subscription" -and $errorMsg -match "feature flags registered") {
            $resultEntry.FeatureFlagRequired = $true
            $resultEntry.UnsupportedVMSize = $true
            # Extract required feature flags from error message
            if ($errorMsg -match "feature flags registered\s*:\s*([^\.\n]+)") {
                $resultEntry.RequiredFeatureFlags = $Matches[1].Trim()
            }
            Write-Log "VM size $VMSize requires feature flag registration (preview/restricted)" "WARN"
            Write-Log "Required flags: $($resultEntry.RequiredFeatureFlags)" "WARN"
            Write-Log "This VM size is in limited preview - register via Azure Portal or contact support" "WARN"
        }

        # Check if securityProfile.securityType conflict (orphaned disk with different security type)
        if ($errorMsg -match "PropertyChangeNotAllowed" -and $errorMsg -match "securityProfile\.securityType") {
            Write-Log "Security type conflict detected - orphaned disk has different security type" "WARN"
            try {
                # Delete the orphaned OS disk and retry
                $existingDisk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName "$vmN-osdisk" -ErrorAction SilentlyContinue
                if ($existingDisk) {
                    Write-Log "Deleting conflicting OS disk: $vmN-osdisk" "WARN"
                    Remove-AzDisk -ResourceGroupName $ResourceGroupName -DiskName "$vmN-osdisk" -Force -ErrorAction Stop
                    Start-Sleep -Seconds 5
                    Write-Log "Retrying VM creation after disk cleanup..." "INFO"

                    # Retry VM creation with original config
                    $vm = New-AzVM @vmParams
                    Write-Log "VM created on retry after disk cleanup: $vmN" "SUCCESS"

                    # Get public IP for the successfully created VM
                    if (-not $NoPublicIP -and $pipName) {
                        try {
                            $publicIpObj = Get-AzPublicIpAddress -Name $pipName -ResourceGroupName $ResourceGroupName -ErrorAction Stop
                            $resultEntry.PublicIP = $publicIpObj.IpAddress
                            Write-Log "Public IP: $($resultEntry.PublicIP)"
                        } catch {
                            Write-Log "Failed to retrieve Public IP: $($_.Exception.Message)" "WARN"
                        }
                    }

                    # Update result entry to success
                    $resultEntry.Success = $true
                    $resultEntry.Remove('Error')
                    $resultEntry.DiskCleanupRetry = $true
                    $resultEntry.AdminPassword = $generatedPassword
                }
            } catch {
                $retryError = $_.Exception.Message
                Write-Log "Retry after disk cleanup also failed: $retryError" "ERROR"
                $resultEntry.RetryError = $retryError
            }
        }

        # Check if TrustedLaunch error - retry with Standard security type (unless TrustedLaunchOnly)
        if ($errorMsg -match "TrustedLaunch" -and $errorMsg -match "not supported") {
            if ($TrustedLaunchOnly) {
                Write-Log "TrustedLaunch not supported for $VMSize and -TrustedLaunchOnly is set, not retrying" "ERROR"
                $resultEntry.TrustedLaunchRequired = $true
            } else {
                Write-Log "TrustedLaunch not supported for $VMSize, retrying with Standard security type..." "WARN"
                try {
                    # Delete orphaned OS disk from failed attempt (prevents security type conflict)
                    $existingDisk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName "$vmN-osdisk" -ErrorAction SilentlyContinue
                    if ($existingDisk) {
                        Write-Log "Deleting orphaned OS disk before retry: $vmN-osdisk" "WARN"
                        Remove-AzDisk -ResourceGroupName $ResourceGroupName -DiskName "$vmN-osdisk" -Force -ErrorAction SilentlyContinue
                        Start-Sleep -Seconds 5
                    }

                    # Rebuild VM config with Standard security type
                    $vmConfigRetry = New-AzVMConfig -VMName $vmN -VMSize $VMSize -Priority "Spot" -EvictionPolicy "Delete" -MaxPrice -1
                    $vmConfigRetry = Set-AzVMSecurityProfile -VM $vmConfigRetry -SecurityType "Standard"
                    $vmConfigRetry = Set-AzVMSourceImage -VM $vmConfigRetry -PublisherName $ImagePublisher -Offer $actualImageOffer -Skus $actualImageSku -Version $ImageVersion
                    $vmConfigRetry = Add-AzVMNetworkInterface -VM $vmConfigRetry -Id $nic.Id -DeleteOption "Delete"
                    $vmConfigRetry = Set-AzVMOSDisk -VM $vmConfigRetry -Name "$vmN-osdisk" -DeleteOption "Delete" -Linux -StorageAccountType $StorageAccountType -CreateOption "FromImage"
                    $vmConfigRetry = Set-AzVMBootDiagnostic -VM $vmConfigRetry -Enable
                    $vmConfigRetry = Set-AzVMOperatingSystem -VM $vmConfigRetry -Linux -ComputerName $vmN -Credential $credential
                    if ($CustomData) {
                        $encodedData = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($CustomData))
                        $vmConfigRetry.OSProfile.CustomData = $encodedData
                    }
                    $vmRetryParams = @{
                        ResourceGroupName = $ResourceGroupName
                        Location = $Location
                        VM = $vmConfigRetry
                        Verbose = $true
                        ErrorAction = "Stop"
                    }
                    $vm = New-AzVM @vmRetryParams
                    Write-Log "VM created on retry with Standard security: $vmN" "SUCCESS"

                    # Update result entry to success
                    $resultEntry.Success = $true
                    $resultEntry.Remove('Error')
                    $resultEntry.SecurityTypeRetry = $true
                } catch {
                    $retryError = $_.Exception.Message
                    Write-Log "Retry with Standard security also failed: $retryError" "ERROR"
                    $resultEntry.RetryError = $retryError
                }
            }
        }

        $results += $resultEntry
    }
}

Write-Log "Completed. Created $($results | Where-Object { $_.Success } | Measure-Object | Select-Object -ExpandProperty Count) of $($vmNames.Count) VMs"

return $results
