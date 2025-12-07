# create-spot-vms.ps1
# Creates Azure VM spot instances (single or batch)
# Copyright 2023-2025 by Maxim Masiutin. All rights reserved.

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

    # Image
    [string]$ImagePublisher = "Canonical",
    [string]$ImageOffer = "0001-com-ubuntu-server-jammy",
    [string]$ImageSku = "22_04-lts-gen2",
    [string]$ImageVersion = "latest",
    [string]$StorageAccountType = "Standard_LRS",
    [string]$SecurityType = "TrustedLaunch",

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
    [switch]$RequestQuota,  # Attempt to auto-request quota increase on failure
    [switch]$BlockSSH       # If set, NSG will be created but SSH traffic blocked (default: allowed)
)

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

function Get-VMFamilyName {
    param([string]$VMSize)
    # Extract short family name for quota API (e.g., D4pls_v5 -> DPLSv5)
    $size = $VMSize -replace "^Standard_", ""
    # Map patterns to family names
    $patterns = @{
        "D.*pls_v5$" = "DPLSv5"
        "D.*ps_v5$"  = "DPSv5"
        "D.*pds_v5$" = "DPDSv5"
        "D.*as_v5$"  = "DASv5"
        "D.*ads_v5$" = "DADSv5"
        "D.*s_v5$"   = "DSv5"
        "F.*s_v2$"   = "FSv2"
        "B.*s_v2$"   = "BSv2"
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
        $pwd = -join ($bytes | ForEach-Object { $alphabet[$_ % 64] })
        
        # Ensure Azure complexity (3 of 4: Upper, Lower, Digit, Special)
        # With length 28, statistical probability of missing a class is near zero, 
        # but we check to be safe. If missing, we inject one of each at random positions.
        $hasUpper = $pwd -cmatch "[A-Z]"
        $hasLower = $pwd -cmatch "[a-z]"
        $hasDigit = $pwd -match "[0-9]"
        $hasSpecial = $pwd -match "[-_]"
        
        if (-not ($hasUpper -and $hasLower -and $hasDigit -and $hasSpecial)) {
            # Fallback: strict injection if RNG somehow missed a class (extremely unlikely)
            $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
            $b = New-Object byte[] 4
            $rng.GetBytes($b)
            
            # Convert string to char array to modify
            $chars = $pwd.ToCharArray()
            
            # Inject missing classes at random indices
            if (-not $hasUpper)   { $chars[$b[0] % $length] = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"[$b[0] % 26] }
            if (-not $hasLower)   { $chars[$b[1] % $length] = "abcdefghijklmnopqrstuvwxyz"[$b[1] % 26] }
            if (-not $hasDigit)   { $chars[$b[2] % $length] = "0123456789"[$b[2] % 10] }
            if (-not $hasSpecial) { $chars[$b[3] % $length] = "-_"[$b[3] % 2] }
            
            $pwd = -join $chars
        }

        $script:AdminPassword = ConvertTo-SecureString $pwd -AsPlainText -Force
        $plaintextPassword = $pwd
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
                    Family = "Total Regional Spot vCPUs"
                }
            } else {
                return @{
                    Success = $false
                    Available = $available
                    Required = $coreCount
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

function Show-QuotaIncreaseInstructions {
    param(
        [string]$Location,
        [string]$Family,
        [int]$RequiredCores
    )

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
            Show-QuotaIncreaseInstructions -Location $Location -Family $quotaResult.Family -RequiredCores $totalCores
            
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
}

# ==== RESOURCE GROUP ====
Write-Log "Checking resource group..."
$rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue

if (-not $rg) {
    Write-Log "Creating resource group: $ResourceGroupName in $Location"
    $rg = New-AzResourceGroup -Name $ResourceGroupName -Location $Location
} else {
    Write-Log "Using existing resource group: $ResourceGroupName"
}

# ==== VIRTUAL NETWORK ====
Write-Log "Checking virtual network..."
$vnet = Get-AzVirtualNetwork -Name $NetworkName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue

if (-not $vnet) {
    Write-Log "Creating virtual network: $NetworkName"
    try {
        $subnetConfig = New-AzVirtualNetworkSubnetConfig -Name $SubnetName -AddressPrefix $SubnetAddressPrefix
        $vnet = New-AzVirtualNetwork -Name $NetworkName -ResourceGroupName $ResourceGroupName -Location $Location -AddressPrefix $VnetAddressPrefix -Subnet $subnetConfig -ErrorAction Stop
    }
    catch {
        $errorMsg = $_.Exception.Message
        Write-Log "Error creating virtual network: $errorMsg" "ERROR"

        if ($errorMsg -match "LocationNotAvailableForResourceType|not available for resource type") {
            Write-Log "Region $Location does not support virtual networks - restricted region" "ERROR"
            return @{
                Success = $false
                UnsupportedRegion = $true
                Error = "Region $Location does not support virtual networks"
                Location = $Location
            }
        }
        throw
    }
} else {
    Write-Log "Using existing virtual network: $NetworkName"
}

# Get subnet ID
$subnetId = ($vnet.Subnets | Where-Object { $_.Name -eq $SubnetName }).Id
if (-not $subnetId) {
    if ($vnet.Subnets.Count -gt 0) {
        $subnetId = $vnet.Subnets[0].Id
        Write-Log "Using first available subnet" "DEBUG"
    } else {
        Write-Log "No subnets found, creating: $SubnetName"
        $subnetConfig = Add-AzVirtualNetworkSubnetConfig -Name $SubnetName -VirtualNetwork $vnet -AddressPrefix $SubnetAddressPrefix
        $vnet | Set-AzVirtualNetwork | Out-Null
        $vnet = Get-AzVirtualNetwork -Name $NetworkName -ResourceGroupName $ResourceGroupName
        $subnetId = ($vnet.Subnets | Where-Object { $_.Name -eq $SubnetName }).Id
    }
}

# ==== NAT GATEWAY (if requested) ====
if ($NoPublicIP -and $UseNatGateway) {
    $natGwName = "$NetworkName-natgw"
    $natGw = Get-AzNatGateway -ResourceGroupName $ResourceGroupName -Name $natGwName -ErrorAction SilentlyContinue

    if (-not $natGw) {
        Write-Log "Creating NAT Gateway: $natGwName"
        $natPip = New-AzPublicIpAddress -Name "$natGwName-pip" -ResourceGroupName $ResourceGroupName -Location $Location -AllocationMethod Static -Sku Standard
        $natGw = New-AzNatGateway -ResourceGroupName $ResourceGroupName -Name $natGwName -Location $Location -PublicIpAddress $natPip -Sku Standard -IdleTimeoutInMinutes 10

        $subnet = Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $vnet -Name $SubnetName
        Set-AzVirtualNetworkSubnetConfig -VirtualNetwork $vnet -Name $SubnetName -AddressPrefix $subnet.AddressPrefix -NatGateway $natGw | Out-Null
        $vnet | Set-AzVirtualNetwork | Out-Null
        Write-Log "NAT Gateway created and associated with subnet"
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
    }

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

    # Public IP
    $pipName = $null
    $nsg = $null
    if (-not $NoPublicIP) {
        $pipName = "$vmN-pip"
        $pip = New-AzPublicIpAddress -Name $pipName -ResourceGroupName $ResourceGroupName -Location $Location -AllocationMethod Static -Sku Standard
        $nicParams.PublicIpAddressId = $pip.Id
        Write-Log "Created public IP: $pipName"

        # Create NSG
        $nsgName = "$vmN-nsg"
        $nsg = Get-AzNetworkSecurityGroup -Name $nsgName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
        
        if (-not $nsg) {
            if ($BlockSSH) {
                Write-Log "Creating NSG: $nsgName (SSH BLOCKED)"
                $nsg = New-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Location $Location -Name $nsgName
            } else {
                Write-Log "Creating NSG: $nsgName (SSH ALLOWED)"
                $ruleSSH = New-AzNetworkSecurityRuleConfig -Name "AllowSSH" -Description "Allow SSH" `
                    -Access Allow -Protocol Tcp -Direction Inbound -Priority 1000 `
                    -SourceAddressPrefix Internet -SourcePortRange * `
                    -DestinationAddressPrefix * -DestinationPortRange 22
                $nsg = New-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Location $Location -Name $nsgName -SecurityRules $ruleSSH
            }
        } else {
            Write-Log "Using existing NSG: $nsgName"
        }
        $nicParams.NetworkSecurityGroupId = $nsg.Id
    } else {
        Write-Log "Skipping public IP creation (NoPublicIP specified)" "INFO"
    }

    $nic = New-AzNetworkInterface @nicParams

    # VM Config
    $vmConfig = New-AzVMConfig -VMName $vmN -VMSize $VMSize -Priority "Spot" -EvictionPolicy "Delete" -MaxPrice -1

    if ($SecurityType) {
        $vmConfig = Set-AzVMSecurityProfile -VM $vmConfig -SecurityType $SecurityType
    }

    $vmConfig = Set-AzVMSourceImage -VM $vmConfig -PublisherName $ImagePublisher -Offer $ImageOffer -Skus $ImageSku -Version $ImageVersion
    $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id -DeleteOption "Delete"
    $vmConfig = Set-AzVMOSDisk -VM $vmConfig -Name "$vmN-osdisk" -DeleteOption "Delete" -Linux -StorageAccountType $StorageAccountType -CreateOption "FromImage"

    if ($SshPublicKey) {
        $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Linux -ComputerName $vmN -Credential $credential -DisablePasswordAuthentication
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

    # Create VM
    try {
        $vm = New-AzVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $vmConfig -Verbose
        Write-Log "VM created: $vmN" "SUCCESS"

        # Run init script via URL (if provided)
        if ($InitScriptUrl) {
            $initCmd = "cd /tmp && wget -q '$InitScriptUrl' -O init.bash && chmod +x init.bash && ./init.bash > /var/log/init.log 2>&1"
            Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmN -CommandId 'RunShellScript' -ScriptString $initCmd -AsJob
            Write-Log "Init script (URL) started as background job"
        }

        # Run local init script via RunCommand (if provided and no cloud-init)
        if ($InitScriptPath -and (Test-Path $InitScriptPath) -and -not $CustomData) {
            $scriptContent = Get-Content $InitScriptPath -Raw
            Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmN -CommandId 'RunShellScript' -ScriptString $scriptContent -AsJob
            Write-Log "Init script (local) started as background job"
        }

        # Get public IP
        $publicIp = $null
        if (-not $NoPublicIP -and $pipName) {
            $publicIp = (Get-AzPublicIpAddress -Name $pipName -ResourceGroupName $ResourceGroupName).IpAddress
            Write-Log "Public IP: $publicIp"
            Write-Log "SSH: ssh $AdminUsername@$publicIp"
        }

        $results += @{
            VMName = $vmN
            Success = $true
            PublicIP = $publicIp
            Location = $Location
            VMSize = $VMSize
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
            Show-QuotaIncreaseInstructions -Location $Location -Family $familyInfo -RequiredCores (Get-VMCoreCount -VMSize $VMSize)
            
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

        $results += $resultEntry
    }
}

Write-Log "Completed. Created $($results | Where-Object { $_.Success } | Measure-Object | Select-Object -ExpandProperty Count) of $($vmNames.Count) VMs"

return $results
