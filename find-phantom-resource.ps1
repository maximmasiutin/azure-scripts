<#
.SYNOPSIS
    Find hidden/phantom resources blocking Azure resource group deletion.

.DESCRIPTION
    Scans an Azure resource group using multiple methods to find resources that
    "az resource list" and "az network * list" miss due to case-sensitivity bugs.

    Root cause: JMESPath client-side filtering in "az network * list --query
    [?resourceGroup=='X']" is CASE-SENSITIVE. Azure stores resource group names
    with inconsistent casing internally (e.g. "FishtestSpotRG-9" vs
    "FISHTESTSPOTRG-9"). When casing differs, JMESPath silently returns zero
    results even though the resources exist.

    The fix: "az rest --method GET" queries the ARM REST API directly using the
    resource group path, bypassing JMESPath. This always returns all resources
    regardless of internal casing.

    Checks performed:
      1. ARM REST API direct query (most reliable, bypasses casing issues)
      2. az resource list (may miss resources with casing mismatch)
      3. NICs, Public IPs, VNets, Subnets, Private Endpoints, DNS Zones
      4. Load Balancers, Route Tables, NSGs
      5. Subscription-wide scan for resources with managedBy field
      6. Failed deployments in the resource group

    With -SubScan: subscription-wide scan for resources in a region whose
    resource group does not exist or is in "Deleting" state.

.PARAMETER ResourceGroup
    Name of the Azure resource group to scan. Required unless -SubScan is used.

.PARAMETER Delete
    Delete orphaned phantom resources found in the resource group.
    Only deletes resources that are BOTH invisible to "az resource list"
    (phantom due to casing bug) AND orphaned (no active dependencies).

    Safe to delete: detached NICs, unattached disks, unused public IPs,
    empty VNets, unused NSGs/route tables.

    Never auto-deleted: VMs, storage accounts, databases, key vaults,
    or any resource with active dependencies.

    Requires -Force to actually execute deletions. Without -Force,
    acts as a dry run (same as -DryRun).

.PARAMETER DryRun
    Show which phantom resources would be deleted, without deleting.

.PARAMETER Force
    Required with -Delete to actually execute deletions.
    Without -Force, -Delete behaves as a dry run.

.PARAMETER DeleteResourceGroup
    After deleting all phantom resources, also delete the resource group
    itself. Requires -Delete and -Force.

.PARAMETER SubScan
    Subscription-wide scan mode. Finds resources whose resource group does not
    exist or is in "Deleting" state. Use with -Region to filter by location.
    Cannot be combined with -ResourceGroup.

.PARAMETER Region
    Azure region name (e.g. "centralindia") to filter resources in -SubScan mode.
    Without this, all regions are scanned (slow).

.EXAMPLE
    pwsh find-phantom-resource.ps1 -ResourceGroup "FishtestSpotRG-10"

    Scans FishtestSpotRG-10 for phantom resources and prints resource IDs.

.EXAMPLE
    pwsh find-phantom-resource.ps1 -ResourceGroup "FishtestSpotRG-10" -DryRun

    Shows which phantom resources are orphaned and safe to delete.

.EXAMPLE
    pwsh find-phantom-resource.ps1 -ResourceGroup "FishtestSpotRG-10" -Delete -Force

    Deletes orphaned phantom resources in the resource group.

.EXAMPLE
    pwsh find-phantom-resource.ps1 -ResourceGroup "FishtestSpotRG-10" -Delete -Force -DeleteResourceGroup

    Deletes orphaned phantom resources, then deletes the resource group.

.EXAMPLE
    pwsh find-phantom-resource.ps1 -SubScan -Region "centralindia"

    Finds all resources in centralindia whose resource group is missing or stuck.

.NOTES
    Requires: Azure CLI (az) authenticated and with an active subscription.
#>

param(
    [Parameter(HelpMessage="Name of the Azure resource group to scan")]
    [string]$ResourceGroup,

    [Parameter(HelpMessage="Subscription-wide scan: find resources whose RG is missing or in Deleting state")]
    [switch]$SubScan,

    [Parameter(HelpMessage="Azure region to filter resources in -SubScan mode (e.g. centralindia)")]
    [string]$Region,

    [Parameter(HelpMessage="Delete orphaned phantom resources")]
    [switch]$Delete,

    [Parameter(HelpMessage="Show what would be deleted without deleting")]
    [switch]$DryRun,

    [Parameter(HelpMessage="Required with -Delete to confirm deletions")]
    [switch]$Force,

    [Parameter(HelpMessage="Also delete the resource group after cleaning phantom resources")]
    [switch]$DeleteResourceGroup
)

# Validate parameter combinations
if ($SubScan -and $ResourceGroup) {
    Write-Host "ERROR: -SubScan and -ResourceGroup are mutually exclusive." -ForegroundColor Red
    exit 1
}
if (-not $SubScan -and -not $ResourceGroup) {
    Write-Host "ERROR: Provide -ResourceGroup <name> or -SubScan." -ForegroundColor Red
    exit 1
}
if ($SubScan -and ($Delete -or $DeleteResourceGroup)) {
    Write-Host "ERROR: -Delete and -DeleteResourceGroup are not supported in -SubScan mode." -ForegroundColor Red
    exit 1
}
if ($DeleteResourceGroup -and (-not $Delete -or -not $Force)) {
    Write-Host "ERROR: -DeleteResourceGroup requires -Delete -Force." -ForegroundColor Red
    exit 1
}
if ($DryRun -and $Delete) {
    Write-Host "ERROR: Use -Delete -Force to delete, or -DryRun to preview. Not both." -ForegroundColor Red
    exit 1
}

# -Delete without -Force is a dry run with a hint
$effectiveDryRun = $DryRun -or ($Delete -and -not $Force)
if ($Delete -and -not $Force) {
    Write-Host "NOTE: -Delete without -Force acts as dry run. Add -Force to execute." -ForegroundColor Yellow
}

# Resource types that are NEVER auto-deleted (active workloads / data stores)
$neverDeleteTypes = @(
    "Microsoft.Compute/virtualMachines",
    "Microsoft.Storage/storageAccounts",
    "Microsoft.Sql/servers",
    "Microsoft.Sql/servers/databases",
    "Microsoft.DocumentDB/databaseAccounts",
    "Microsoft.KeyVault/vaults",
    "Microsoft.ContainerRegistry/registries",
    "Microsoft.ContainerService/managedClusters",
    "Microsoft.Web/sites",
    "Microsoft.Web/serverFarms",
    "Microsoft.CognitiveServices/accounts",
    "Microsoft.MachineLearningServices/workspaces"
)

# Resource types that are safe to delete when orphaned
$safeDeleteTypes = @(
    "Microsoft.Compute/disks",
    "Microsoft.Network/networkInterfaces",
    "Microsoft.Network/publicIPAddresses",
    "Microsoft.Network/virtualNetworks",
    "Microsoft.Network/networkSecurityGroups",
    "Microsoft.Network/routeTables",
    "Microsoft.Network/loadBalancers",
    "Microsoft.Network/privateDnsZones",
    "Microsoft.Network/privateEndpoints"
)

function Invoke-AzRest {
    <#
    .SYNOPSIS
        Call az rest and return parsed JSON, or $null on failure.
    #>
    param([string]$Url)
    try {
        $result = az rest --method GET --url $Url --only-show-errors 2>&1
        if ($LASTEXITCODE -ne 0) { return $null }
        return $result | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Test-ResourceOrphaned {
    <#
    .SYNOPSIS
        Check if a resource is orphaned (no active dependencies).
    .DESCRIPTION
        Queries the resource via REST API to inspect attachment/dependency fields.
        Returns $true if the resource has no active parent or consumer.
    #>
    param(
        [string]$ResourceId,
        [string]$ResourceType
    )

    switch ($ResourceType) {
        "Microsoft.Compute/disks" {
            $disk = Invoke-AzRest -Url "${ResourceId}?api-version=2024-03-02"
            if ($null -ne $disk) {
                $managedBy = $disk.managedBy
                if ([string]::IsNullOrWhiteSpace($managedBy)) {
                    return $true
                }
                $vmCheck = Invoke-AzRest -Url "${managedBy}?api-version=2024-07-01"
                if ($null -eq $vmCheck) {
                    return $true  # VM no longer exists
                }
            }
            return $false
        }
        "Microsoft.Network/networkInterfaces" {
            $nic = Invoke-AzRest -Url "${ResourceId}?api-version=2024-01-01"
            if ($null -ne $nic) {
                $vmRef = $nic.properties.virtualMachine
                if ($null -eq $vmRef -or [string]::IsNullOrWhiteSpace($vmRef.id)) {
                    return $true
                }
                $vmCheck = Invoke-AzRest -Url "$($vmRef.id)?api-version=2024-07-01"
                if ($null -eq $vmCheck) {
                    return $true  # VM no longer exists
                }
            }
            return $false
        }
        "Microsoft.Network/publicIPAddresses" {
            $pip = Invoke-AzRest -Url "${ResourceId}?api-version=2024-01-01"
            if ($null -ne $pip) {
                $ipConfig = $pip.properties.ipConfiguration
                if ($null -eq $ipConfig -or [string]::IsNullOrWhiteSpace($ipConfig.id)) {
                    return $true
                }
            }
            return $false
        }
        "Microsoft.Network/virtualNetworks" {
            $vnet = Invoke-AzRest -Url "${ResourceId}?api-version=2024-01-01"
            if ($null -ne $vnet) {
                $subnets = $vnet.properties.subnets
                if ($null -eq $subnets -or $subnets.Count -eq 0) {
                    return $true
                }
                foreach ($subnet in $subnets) {
                    $ipConfigs = $subnet.properties.ipConfigurations
                    if ($null -ne $ipConfigs -and $ipConfigs.Count -gt 0) {
                        return $false
                    }
                    $delegations = $subnet.properties.delegations
                    if ($null -ne $delegations -and $delegations.Count -gt 0) {
                        return $false
                    }
                }
                return $true
            }
            return $false
        }
        "Microsoft.Network/networkSecurityGroups" {
            $nsg = Invoke-AzRest -Url "${ResourceId}?api-version=2024-01-01"
            if ($null -ne $nsg) {
                $subnets = $nsg.properties.subnets
                $nics = $nsg.properties.networkInterfaces
                if (($null -eq $subnets -or $subnets.Count -eq 0) -and
                    ($null -eq $nics -or $nics.Count -eq 0)) {
                    return $true
                }
            }
            return $false
        }
        "Microsoft.Network/routeTables" {
            $rt = Invoke-AzRest -Url "${ResourceId}?api-version=2024-01-01"
            if ($null -ne $rt) {
                $subnets = $rt.properties.subnets
                if ($null -eq $subnets -or $subnets.Count -eq 0) {
                    return $true
                }
            }
            return $false
        }
        "Microsoft.Network/loadBalancers" {
            $lb = Invoke-AzRest -Url "${ResourceId}?api-version=2024-01-01"
            if ($null -ne $lb) {
                $pools = $lb.properties.backendAddressPools
                if ($null -eq $pools -or $pools.Count -eq 0) {
                    return $true
                }
                foreach ($pool in $pools) {
                    $targets = $pool.properties.backendIPConfigurations
                    if ($null -ne $targets -and $targets.Count -gt 0) {
                        return $false
                    }
                }
                return $true
            }
            return $false
        }
        "Microsoft.Network/privateEndpoints" {
            $pe = Invoke-AzRest -Url "${ResourceId}?api-version=2024-01-01"
            if ($null -ne $pe) {
                $connections = $pe.properties.privateLinkServiceConnections
                $manualConns = $pe.properties.manualPrivateLinkServiceConnections
                $allConns = @()
                if ($null -ne $connections) { $allConns += $connections }
                if ($null -ne $manualConns) { $allConns += $manualConns }
                if ($allConns.Count -eq 0) {
                    return $true
                }
                foreach ($conn in $allConns) {
                    $status = $conn.properties.privateLinkServiceConnectionState.status
                    if ($status -eq "Approved" -or $status -eq "Pending") {
                        return $false  # Active connection
                    }
                }
                return $true  # All connections disconnected/rejected
            }
            return $false
        }
        "Microsoft.Network/privateDnsZones" {
            $zone = Invoke-AzRest -Url "${ResourceId}?api-version=2024-06-01"
            if ($null -ne $zone) {
                $vnetLinks = Invoke-AzRest -Url "${ResourceId}/virtualNetworkLinks?api-version=2024-06-01"
                if ($null -ne $vnetLinks -and $null -ne $vnetLinks.value -and $vnetLinks.value.Count -gt 0) {
                    return $false  # Has VNet links
                }
                $recordSets = $zone.properties.numberOfRecordSets
                if ($null -ne $recordSets -and $recordSets -gt 2) {
                    return $false  # Has records beyond SOA+NS defaults
                }
                return $true
            }
            return $false
        }
        default {
            # Unknown type in safe-delete list: do NOT assume orphaned
            return $false
        }
    }
}

# ============================================================
# SUBSCAN MODE: subscription-wide orphan search by region
# ============================================================
if ($SubScan) {
    $subscriptionId = az account show --query id -o tsv
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Failed to get subscription ID." -ForegroundColor Red
        exit 1
    }

    $regionLabel = if ($Region) { $Region } else { "all regions" }
    Write-Host "Subscription-wide orphan scan: $regionLabel" -ForegroundColor Cyan
    Write-Host "Subscription: $subscriptionId`n"

    # Use Azure Resource Graph for reliable subscription-wide query.
    # The ARM REST $filter=location is known to return incomplete results.
    # Resource Graph requires the resource-graph extension: az extension add --name resource-graph
    $allResources = [System.Collections.Generic.List[object]]::new()
    $locationFilter = if ($Region) { "| where location == '$Region'" } else { "" }
    $kqlQuery = "Resources $locationFilter | project id, name, type, location, resourceGroup"
    Write-Host "  Running Resource Graph query..."
    $graphJson = az graph query -q $kqlQuery --output json --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Resource Graph query failed: $graphJson" -ForegroundColor Red
        Write-Host "Ensure the resource-graph extension is installed: az extension add --name resource-graph" -ForegroundColor Yellow
        exit 1
    }
    try {
        $graphResult = $graphJson | ConvertFrom-Json
        $items = $graphResult.data
        if ($null -ne $items) {
            foreach ($item in $items) { $allResources.Add($item) }
        }
    } catch {
        Write-Host "ERROR: Failed to parse Resource Graph response: $_" -ForegroundColor Red
        exit 1
    }

    Write-Host "  Total resources retrieved: $($allResources.Count)`n"

    if ($allResources.Count -eq 0) {
        Write-Host "No resources found for the specified filter." -ForegroundColor Yellow
        exit 0
    }

    # Cache RG status to avoid redundant queries
    $rgStatusCache = @{}

    function Get-RgStatus {
        param([string]$RgName)
        $key = $RgName.ToLower()
        if ($rgStatusCache.ContainsKey($key)) {
            return $rgStatusCache[$key]
        }
        $rgData = Invoke-AzRest -Url "/subscriptions/$subscriptionId/resourceGroups/$RgName`?api-version=2021-04-01"
        if ($null -eq $rgData) {
            $rgStatusCache[$key] = "NotFound"
            return "NotFound"
        }
        $state = $rgData.properties.provisioningState
        $rgStatusCache[$key] = $state
        return $state
    }

    # Check each resource's RG
    $orphanedResources = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $allResources) {
        $rgName = $r.resourceGroup
        if ([string]::IsNullOrWhiteSpace($rgName)) {
            continue
        }
        $rgStatus = Get-RgStatus -RgName $rgName
        if ($rgStatus -eq "NotFound" -or $rgStatus -eq "Deleting") {
            $orphanedResources.Add([PSCustomObject]@{
                Name          = $r.name
                Type          = $r.type
                Location      = $r.location
                ResourceGroup = $rgName
                RgStatus      = $rgStatus
                Id            = $r.id
            })
        }
    }

    if ($orphanedResources.Count -eq 0) {
        Write-Host "No orphaned resources found (all resource groups active)." -ForegroundColor Green
    } else {
        Write-Host "=== Orphaned Resources (RG missing or in Deleting state) ===" -ForegroundColor Yellow
        Write-Host "  Found $($orphanedResources.Count) orphaned resource(s):`n" -ForegroundColor Yellow
        $orphanedResources | Format-Table Name, Type, Location, ResourceGroup, RgStatus -AutoSize
        Write-Host "`n  Resource IDs:" -ForegroundColor Yellow
        foreach ($o in $orphanedResources) {
            Write-Host "    [$($o.RgStatus)] $($o.Id)"
        }
    }
    Write-Host "`nScan complete." -ForegroundColor Green
    exit 0
}

# ============================================================
# SINGLE-RG MODE
# ============================================================
Write-Host "Scanning for phantom resources in RG: $ResourceGroup" -ForegroundColor Cyan

# 0. REST API direct query - most reliable method.
Write-Host "`n=== REST API Direct Query (most reliable) ==="
$subscriptionId = az account show --query id -o tsv
$restUrl = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/resources?api-version=2024-03-01"
$restResult = az rest --method GET --url $restUrl --only-show-errors 2>&1
$restResources = @()
if ($LASTEXITCODE -eq 0) {
    try {
        $parsed = $restResult | ConvertFrom-Json
        if ($parsed.value.Count -gt 0) {
            $restResources = $parsed.value
            Write-Host "  Found $($restResources.Count) resource(s) via REST API:" -ForegroundColor Yellow
            $restResources | Format-Table name, type, location -AutoSize
            Write-Host "`n  Resource IDs (use 'az resource delete --ids <id>' to remove):" -ForegroundColor Yellow
            foreach ($r in $restResources) {
                Write-Host "    $($r.id)"
            }
        } else {
            Write-Host "  No resources found via REST API"
        }
    } catch {
        Write-Host "  ERROR: Failed to parse REST API response: $_" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "  REST API query failed: $restResult" -ForegroundColor Red
}

# 1. Generic ARM resources (may miss resources with casing mismatch)
Write-Host "`n=== ARM Resources (az resource list) ==="
$armListJson = az resource list -g $ResourceGroup -o json --only-show-errors 2>&1
$armResources = @()
if ($LASTEXITCODE -eq 0) {
    try {
        $armParsed = $armListJson | ConvertFrom-Json
        if ($armParsed.Count -gt 0) {
            $armResources = $armParsed
            $armResources | Format-Table name, type, location -AutoSize
        } else {
            Write-Host "  (none visible - likely casing mismatch)"
        }
    } catch {
        Write-Host "  ERROR: Failed to parse az resource list output." -ForegroundColor Red
        Write-Host "  Aborting to prevent misclassifying resources as phantom." -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "  ERROR: az resource list failed (auth/subscription issue?)." -ForegroundColor Red
    Write-Host "  Aborting to prevent misclassifying resources as phantom." -ForegroundColor Red
    exit 1
}

# Identify phantom resources: in REST API but not in az resource list
$armIds = @{}
foreach ($r in $armResources) {
    $armIds[$r.id.ToLower()] = $true
}
$phantomResources = [System.Collections.Generic.List[object]]::new()
foreach ($r in $restResources) {
    if (-not $armIds.ContainsKey($r.id.ToLower())) {
        $phantomResources.Add($r)
    }
}

if ($phantomResources.Count -gt 0) {
    Write-Host "`n=== Phantom Resources (invisible to 'az resource list') ===" -ForegroundColor Yellow
    Write-Host "  Found $($phantomResources.Count) phantom resource(s):" -ForegroundColor Yellow
    $phantomResources | Format-Table name, type, location -AutoSize
} else {
    Write-Host "`n  No phantom resources detected (all resources visible to 'az resource list')."
}

# 2. NICs (case-sensitive JMESPath filter)
Write-Host "`n=== Network Interfaces (NICs) ==="
az network nic list --query "[?resourceGroup=='$ResourceGroup']" -o table

# 3. Public IPs (case-sensitive JMESPath filter)
Write-Host "`n=== Public IP Addresses ==="
az network public-ip list --query "[?resourceGroup=='$ResourceGroup']" -o table

# 4. VNets (case-sensitive JMESPath filter)
Write-Host "`n=== Virtual Networks ==="
az network vnet list --query "[?resourceGroup=='$ResourceGroup']" -o table

# 5. Subnets (per-vnet in resource group)
Write-Host "`n=== Subnets ==="
$vnets = az network vnet list -g $ResourceGroup --query "[].name" -o tsv
if ($vnets) {
    foreach ($vnet in $vnets) {
        Write-Host "  VNet: $vnet"
        az network vnet subnet list -g $ResourceGroup --vnet-name $vnet -o table
    }
} else {
    Write-Host "  No VNets found in $ResourceGroup"
}

# 6. Private Endpoints
Write-Host "`n=== Private Endpoints ==="
az network private-endpoint list --query "[?resourceGroup=='$ResourceGroup']" -o table

# 7. Private DNS Zones
Write-Host "`n=== Private DNS Zones ==="
az network private-dns zone list --query "[?resourceGroup=='$ResourceGroup']" -o table

# 8. Load Balancers
Write-Host "`n=== Load Balancers ==="
az network lb list --query "[?resourceGroup=='$ResourceGroup']" -o table

# 9. Route Tables
Write-Host "`n=== Route Tables ==="
az network route-table list --query "[?resourceGroup=='$ResourceGroup']" -o table

# 10. Network Security Groups
Write-Host "`n=== Network Security Groups (NSGs) ==="
az network nsg list --query "[?resourceGroup=='$ResourceGroup']" -o table

# 11. Subscription-wide scan for resources with managedBy field
Write-Host "`n=== Resources with managedBy field (often hidden/orphaned) ==="
az resource list --query "[?managedBy!='']" -o table

# 12. Failed deployments
Write-Host "`n=== Failed Deployments ==="
az deployment group list -g $ResourceGroup -o table

# --- Delete / DryRun mode ---
if ($DryRun -or $Delete) {
    Write-Host "`n=============================================" -ForegroundColor Cyan
    if ($effectiveDryRun) {
        Write-Host "=== DRY RUN: Analyzing phantom resources ===" -ForegroundColor Cyan
    } else {
        Write-Host "=== DELETE MODE: Analyzing phantom resources ===" -ForegroundColor Red
    }
    Write-Host "=============================================`n" -ForegroundColor Cyan

    if ($phantomResources.Count -eq 0) {
        Write-Host "  No phantom resources to process." -ForegroundColor Green
        Write-Host "`nScan complete." -ForegroundColor Green
        exit 0
    }

    $toDelete = [System.Collections.Generic.List[object]]::new()
    $toSkip = [System.Collections.Generic.List[object]]::new()

    foreach ($r in $phantomResources) {
        $rType = $r.type
        $rName = $r.name
        $rId = $r.id

        # Check never-delete list first
        if ($neverDeleteTypes -contains $rType) {
            $toSkip.Add([PSCustomObject]@{
                Name = $rName
                Type = $rType
                Reason = "Protected type (active workload)"
                Id = $rId
            })
            continue
        }

        # Check if type is in safe-delete list
        if ($safeDeleteTypes -notcontains $rType) {
            $toSkip.Add([PSCustomObject]@{
                Name = $rName
                Type = $rType
                Reason = "Unknown type (not in safe-delete list)"
                Id = $rId
            })
            continue
        }

        # Check if orphaned
        Write-Host "  Checking: $rName ($rType)..." -NoNewline
        $isOrphaned = Test-ResourceOrphaned -ResourceId $rId -ResourceType $rType
        if ($isOrphaned) {
            Write-Host " ORPHANED" -ForegroundColor Yellow
            $toDelete.Add([PSCustomObject]@{
                Name = $rName
                Type = $rType
                Id = $rId
            })
        } else {
            Write-Host " IN USE" -ForegroundColor Green
            $toSkip.Add([PSCustomObject]@{
                Name = $rName
                Type = $rType
                Reason = "Has active dependencies"
                Id = $rId
            })
        }
    }

    # Report
    if ($toSkip.Count -gt 0) {
        Write-Host "`n  SKIPPED (will NOT delete):" -ForegroundColor Green
        foreach ($s in $toSkip) {
            Write-Host "    [SKIP] $($s.Name) ($($s.Type)) - $($s.Reason)" -ForegroundColor Green
        }
    }

    if ($toDelete.Count -gt 0) {
        Write-Host "`n  DELETABLE (orphaned phantom resources):" -ForegroundColor Yellow
        foreach ($d in $toDelete) {
            Write-Host "    [DELETE] $($d.Name) ($($d.Type))" -ForegroundColor Yellow
            Write-Host "             $($d.Id)" -ForegroundColor DarkYellow
        }

        if ($effectiveDryRun) {
            Write-Host "`n  DRY RUN: No resources were deleted." -ForegroundColor Cyan
            Write-Host "  To delete, run with: -Delete -Force" -ForegroundColor Cyan
        } else {
            Write-Host "`n  Deleting $($toDelete.Count) orphaned phantom resource(s)..." -ForegroundColor Red

            # Delete in dependency order: NICs before VNets, disks anytime
            $deleteOrder = @(
                "Microsoft.Compute/disks",
                "Microsoft.Network/networkInterfaces",
                "Microsoft.Network/publicIPAddresses",
                "Microsoft.Network/loadBalancers",
                "Microsoft.Network/privateEndpoints",
                "Microsoft.Network/privateDnsZones",
                "Microsoft.Network/networkSecurityGroups",
                "Microsoft.Network/routeTables",
                "Microsoft.Network/virtualNetworks"
            )

            $deletedCount = 0
            $failedCount = 0

            foreach ($dtype in $deleteOrder) {
                $batch = $toDelete | Where-Object { $_.Type -eq $dtype }
                foreach ($d in $batch) {
                    Write-Host "    Deleting $($d.Name) ($($d.Type))..." -NoNewline
                    $deleteOutput = az resource delete --ids $d.Id 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host " OK" -ForegroundColor Green
                        $deletedCount++
                    } else {
                        Write-Host " FAILED" -ForegroundColor Red
                        Write-Host "      Error: $deleteOutput" -ForegroundColor DarkRed
                        $failedCount++
                    }
                }
            }

            Write-Host "`n  Deleted: $deletedCount, Failed: $failedCount" -ForegroundColor $(if ($failedCount -gt 0) { "Yellow" } else { "Green" })

            if ($DeleteResourceGroup -and $failedCount -eq 0) {
                # Re-check if the RG is now empty
                $remainParsed = Invoke-AzRest -Url "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/resources?api-version=2024-03-01"
                if ($null -eq $remainParsed) {
                    Write-Host "`n  ERROR: Could not verify RG is empty (REST query failed). Skipping RG deletion for safety." -ForegroundColor Red
                } elseif ($null -eq $remainParsed.value) {
                    Write-Host "`n  ERROR: Unexpected REST response (no .value). Skipping RG deletion for safety." -ForegroundColor Red
                } elseif ($remainParsed.value.Count -eq 0) {
                    Write-Host "`n  Resource group is empty. Deleting $ResourceGroup..." -NoNewline
                    $rgDeleteOutput = az group delete -n $ResourceGroup --yes 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host " OK" -ForegroundColor Green
                    } else {
                        Write-Host " FAILED" -ForegroundColor Red
                        Write-Host "      Error: $rgDeleteOutput" -ForegroundColor DarkRed
                    }
                } else {
                    Write-Host "`n  Resource group still has $($remainParsed.value.Count) resource(s). Skipping RG deletion." -ForegroundColor Yellow
                    Write-Host "  Run the scan again to see remaining resources." -ForegroundColor Yellow
                }
            }
        }
    } else {
        Write-Host "`n  No orphaned phantom resources found to delete." -ForegroundColor Green
        if ($phantomResources.Count -gt 0) {
            Write-Host "  All phantom resources have active dependencies or are protected types." -ForegroundColor Yellow
        }
    }
}

Write-Host "`nScan complete." -ForegroundColor Green
