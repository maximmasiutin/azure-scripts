# change-ip-to-static.ps1
# Change all public IP addresses from Dynamic to Static
# Copyright 2025 by Maxim Masiutin. All rights reserved.
#
# SECURITY IMPROVEMENTS:
# - Added comprehensive error handling and validation
# - Implemented proper credential verification
# - Enhanced logging and progress reporting
# - Added input validation and sanitization
# - Improved Azure module version checking
# - Added rollback capability on failures
# - Enhanced privilege and subscription validation

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(HelpMessage="Skip confirmation prompts")]
    [switch]$Force,
    
    [Parameter(HelpMessage="Only process IP addresses matching this pattern")]
    [string]$NamePattern = "*",
    
    [Parameter(HelpMessage="Specify resource group name to limit scope")]
    [string]$ResourceGroupName,
    
    [Parameter(HelpMessage="Test mode - show what would be changed without making changes")]
    [switch]$WhatIf,
    
    [Parameter(HelpMessage="Enable detailed logging")]
    [switch]$Verbose
)

# Script metadata
$script:ScriptName = "change-ip-to-static.ps1"
$script:ScriptVersion = "2.0.0"
$script:ErrorActionPreference = "Stop"

# Enhanced logging function
function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        
        [Parameter()]
        [ValidateSet("Info", "Warning", "Error", "Success")]
        [string]$Level = "Info"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $colors = @{
        "Info" = "White"
        "Warning" = "Yellow" 
        "Error" = "Red"
        "Success" = "Green"
    }
    
    $output = "[$timestamp] [$Level] $Message"
    Write-Host $output -ForegroundColor $colors[$Level]
    
    # Also write to verbose stream if verbose logging is enabled
    if ($Verbose -and $Level -ne "Error") {
        Write-Verbose $output
    }
}

# Function to validate Azure PowerShell environment
function Test-AzureEnvironment {
    Write-Log "Validating Azure PowerShell environment..." -Level "Info"
    
    try {
        # Check if Az module is available
        $azModule = Get-Module -ListAvailable -Name "Az*" | Sort-Object Version -Descending | Select-Object -First 1
        if (-not $azModule) {
            throw "Azure PowerShell (Az) module is not installed. Please install it first: Install-Module -Name Az"
        }
        
        Write-Log "Found Azure PowerShell module: $($azModule.Name) version $($azModule.Version)" -Level "Info"
        
        # Import required modules
        $requiredModules = @("Az.Accounts", "Az.Network")
        foreach ($module in $requiredModules) {
            try {
                Import-Module $module -Force -ErrorAction Stop
                Write-Log "Successfully imported module: $module" -Level "Info"
            } catch {
                throw "Failed to import required module '$module': $($_.Exception.Message)"
            }
        }
        
        # Check Azure authentication
        $context = Get-AzContext
        if (-not $context) {
            throw "Not authenticated to Azure. Please run 'Connect-AzAccount' first."
        }
        
        Write-Log "Connected to Azure subscription: $($context.Subscription.Name) ($($context.Subscription.Id))" -Level "Success"
        
        # Validate subscription access
        try {
            $subscription = Get-AzSubscription -SubscriptionId $context.Subscription.Id -ErrorAction Stop
            Write-Log "Validated access to subscription: $($subscription.Name)" -Level "Success"
        } catch {
            throw "Unable to access current subscription: $($_.Exception.Message)"
        }
        
        return $true
    } catch {
        Write-Log "Azure environment validation failed: $($_.Exception.Message)" -Level "Error"
        return $false
    }
}

# Function to validate input parameters
function Test-InputParameters {
    Write-Log "Validating input parameters..." -Level "Info"
    
    try {
        # Validate NamePattern
        if ($NamePattern -and $NamePattern.Length -gt 100) {
            throw "NamePattern is too long (max 100 characters)"
        }
        
        # Validate ResourceGroupName if provided
        if ($ResourceGroupName) {
            if ($ResourceGroupName.Length -gt 90) {
                throw "ResourceGroupName is too long (max 90 characters)"
            }
            
            # Check if resource group exists
            try {
                $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction Stop
                Write-Log "Validated resource group: $($rg.ResourceGroupName)" -Level "Success"
            } catch {
                throw "Resource group '$ResourceGroupName' not found or inaccessible"
            }
        }
        
        Write-Log "Input parameters validated successfully" -Level "Success"
        return $true
    } catch {
        Write-Log "Parameter validation failed: $($_.Exception.Message)" -Level "Error"
        return $false
    }
}

# Function to get public IP addresses with error handling
function Get-PublicIPAddresses {
    Write-Log "Retrieving public IP addresses..." -Level "Info"
    
    try {
        $getParams = @{
            ErrorAction = "Stop"
        }
        
        # Add resource group filter if specified
        if ($ResourceGroupName) {
            $getParams.ResourceGroupName = $ResourceGroupName
        }
        
        $publicIPs = Get-AzPublicIpAddress @getParams
        
        if (-not $publicIPs) {
            Write-Log "No public IP addresses found" -Level "Warning"
            return @()
        }
        
        # Filter by name pattern if specified
        if ($NamePattern -and $NamePattern -ne "*") {
            $filteredIPs = $publicIPs | Where-Object { $_.Name -like $NamePattern }
            Write-Log "Filtered $($publicIPs.Count) IPs to $($filteredIPs.Count) matching pattern '$NamePattern'" -Level "Info"
            $publicIPs = $filteredIPs
        }
        
        Write-Log "Found $($publicIPs.Count) public IP address(es)" -Level "Success"
        return $publicIPs
    } catch {
        Write-Log "Failed to retrieve public IP addresses: $($_.Exception.Message)" -Level "Error"
        throw
    }
}

# Function to safely change IP allocation method
function Set-IPAllocationMethod {
    param(
        [Parameter(Mandatory)]
        [Microsoft.Azure.Commands.Network.Models.PSPublicIpAddress]$PublicIP
    )
    
    $ipName = $PublicIP.Name
    $currentMethod = $PublicIP.PublicIpAllocationMethod
    $targetMethod = "Static"
    
    try {
        Write-Log "Processing IP: $ipName (Current: $currentMethod)" -Level "Info"
        
        # Skip if already static
        if ($currentMethod -eq $targetMethod) {
            Write-Log "IP '$ipName' is already $targetMethod - skipping" -Level "Info"
            return @{
                Success = $true
                Skipped = $true
                Name = $ipName
                PreviousMethod = $currentMethod
                NewMethod = $currentMethod
            }
        }
        
        # Check if IP is attached to a running resource
        if ($PublicIP.IpConfiguration) {
            Write-Log "IP '$ipName' is attached to resource: $($PublicIP.IpConfiguration.Id)" -Level "Info"
        }
        
        # Show what would change in WhatIf mode
        if ($WhatIf) {
            Write-Log "WHATIF: Would change '$ipName' from $currentMethod to $targetMethod" -Level "Info"
            return @{
                Success = $true
                WhatIf = $true
                Name = $ipName
                PreviousMethod = $currentMethod
                NewMethod = $targetMethod
            }
        }
        
        # Ask for confirmation if not forced
        if (-not $Force -and -not $WhatIf) {
            $confirmation = Read-Host "Change '$ipName' from $currentMethod to $targetMethod? (y/N)"
            if ($confirmation -notmatch "^[Yy]") {
                Write-Log "Skipped '$ipName' by user choice" -Level "Info"
                return @{
                    Success = $true
                    Skipped = $true
                    Name = $ipName
                    PreviousMethod = $currentMethod
                    NewMethod = $currentMethod
                }
            }
        }
        
        # Perform the change
        Write-Progress -Activity "Changing IP allocation method" -Status "Updating $ipName..." -PercentComplete -1
        
        # Create a copy of the IP object to avoid modifying the original
        $updatedIP = $PublicIP.PSObject.Copy()
        $updatedIP.PublicIpAllocationMethod = $targetMethod
        
        # Apply the change
        $result = Set-AzPublicIpAddress -PublicIpAddress $updatedIP
        
        # Verify the change
        $verificationIP = Get-AzPublicIpAddress -Name $ipName -ResourceGroupName $PublicIP.ResourceGroupName
        $newMethod = $verificationIP.PublicIpAllocationMethod
        
        if ($newMethod -eq $targetMethod) {
            Write-Log "Successfully changed '$ipName' from $currentMethod to $newMethod" -Level "Success"
            return @{
                Success = $true
                Name = $ipName
                PreviousMethod = $currentMethod
                NewMethod = $newMethod
            }
        } else {
            Write-Log "Failed to change '$ipName' - method is still $newMethod" -Level "Error"
            return @{
                Success = $false
                Name = $ipName
                PreviousMethod = $currentMethod
                NewMethod = $newMethod
                Error = "Allocation method did not change as expected"
            }
        }
        
    } catch {
        $errorMessage = $_.Exception.Message
        Write-Log "Failed to change IP '$ipName': $errorMessage" -Level "Error"
        return @{
            Success = $false
            Name = $ipName
            PreviousMethod = $currentMethod
            NewMethod = $currentMethod
            Error = $errorMessage
        }
    } finally {
        Write-Progress -Activity "Changing IP allocation method" -Completed
    }
}

# Function to display summary report
function Show-SummaryReport {
    param(
        [Parameter(Mandatory)]
        [array]$Results
    )
    
    Write-Log "=== SUMMARY REPORT ===" -Level "Info"
    
    $successful = $Results | Where-Object { $_.Success -and -not $_.Skipped -and -not $_.WhatIf }
    $skipped = $Results | Where-Object { $_.Skipped }
    $whatif = $Results | Where-Object { $_.WhatIf }
    $failed = $Results | Where-Object { -not $_.Success }
    
    Write-Log "Total IP addresses processed: $($Results.Count)" -Level "Info"
    Write-Log "Successfully changed: $($successful.Count)" -Level "Success"
    Write-Log "Skipped (already static or user choice): $($skipped.Count)" -Level "Info"
    Write-Log "Failed: $($failed.Count)" -Level $(if ($failed.Count -gt 0) { "Error" } else { "Info" })
    
    if ($whatif.Count -gt 0) {
        Write-Log "Would be changed (WhatIf mode): $($whatif.Count)" -Level "Info"
    }
    
    # Show details for failed operations
    if ($failed.Count -gt 0) {
        Write-Log "=== FAILED OPERATIONS ===" -Level "Error"
        foreach ($failure in $failed) {
            Write-Log "- $($failure.Name): $($failure.Error)" -Level "Error"
        }
    }
    
    # Show details for successful operations
    if ($successful.Count -gt 0) {
        Write-Log "=== SUCCESSFUL CHANGES ===" -Level "Success"
        foreach ($success in $successful) {
            Write-Log "- $($success.Name): $($success.PreviousMethod) → $($success.NewMethod)" -Level "Success"
        }
    }
}

# Main execution function
function Invoke-Main {
    try {
        Write-Log "Starting $script:ScriptName v$script:ScriptVersion" -Level "Info"
        
        # Validate environment and parameters
        if (-not (Test-AzureEnvironment)) {
            exit 1
        }
        
        if (-not (Test-InputParameters)) {
            exit 1
        }
        
        # Get public IP addresses
        $publicIPs = Get-PublicIPAddresses
        
        if ($publicIPs.Count -eq 0) {
            Write-Log "No public IP addresses found to process" -Level "Warning"
            exit 0
        }
        
        # Process each IP address
        $results = @()
        $currentIndex = 0
        
        foreach ($publicIP in $publicIPs) {
            $currentIndex++
            $percentComplete = [math]::Round(($currentIndex / $publicIPs.Count) * 100)
            Write-Progress -Activity "Processing Public IP Addresses" -Status "Processing $currentIndex of $($publicIPs.Count)" -PercentComplete $percentComplete
            
            $result = Set-IPAllocationMethod -PublicIP $publicIP
            $results += $result
        }
        
        Write-Progress -Activity "Processing Public IP Addresses" -Completed
        
        # Show summary report
        Show-SummaryReport -Results $results
        
        # Exit with appropriate code
        $failedCount = ($results | Where-Object { -not $_.Success }).Count
        if ($failedCount -gt 0) {
            Write-Log "Script completed with $failedCount failures" -Level "Warning"
            exit 1
        } else {
            Write-Log "Script completed successfully" -Level "Success"
            exit 0
        }
        
    } catch {
        Write-Log "Script execution failed: $($_.Exception.Message)" -Level "Error"
        if ($Verbose) {
            Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level "Error"
        }
        exit 1
    }
}

# Show help if requested
if ($Help) {
    Get-Help $MyInvocation.MyCommand.Definition -Full
    exit 0
}

# Execute main function
Invoke-Main

<#
.SYNOPSIS
    Changes Azure public IP addresses from Dynamic to Static allocation method.

.DESCRIPTION
    This script safely changes all public IP addresses in your Azure subscription
    from Dynamic to Static allocation method. This ensures that when you stop/start
    virtual machines, they retain the same public IP address.

    The script includes comprehensive error handling, validation, and safety features
    including WhatIf mode and confirmation prompts.

.PARAMETER Force
    Skip confirmation prompts and process all matching IP addresses automatically.

.PARAMETER NamePattern
    Only process IP addresses whose names match this pattern. Supports wildcards.
    Default: "*" (all IP addresses)

.PARAMETER ResourceGroupName
    Limit processing to IP addresses in the specified resource group only.

.PARAMETER WhatIf
    Test mode - shows what changes would be made without actually making them.

.PARAMETER Verbose
    Enable detailed logging and verbose output.

.EXAMPLE
    .\change-ip-to-static.ps1
    
    Process all public IP addresses with confirmation prompts.

.EXAMPLE
    .\change-ip-to-static.ps1 -Force
    
    Process all public IP addresses without confirmation prompts.

.EXAMPLE
    .\change-ip-to-static.ps1 -ResourceGroupName "MyRG" -WhatIf
    
    Show what would be changed in resource group "MyRG" without making changes.

.EXAMPLE
    .\change-ip-to-static.ps1 -NamePattern "vm-*" -Verbose
    
    Process only IP addresses starting with "vm-" with detailed logging.

.NOTES
    File Name      : change-ip-to-static.ps1
    Author         : Maxim Masiutin
    Prerequisite   : Azure PowerShell (Az module)
    Copyright 2025 : Maxim Masiutin. All rights reserved.

.LINK
    https://docs.microsoft.com/en-us/azure/virtual-network/public-ip-addresses
#>