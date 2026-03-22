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

    With -SubScan: iterates all resource groups in the subscription (optionally
    filtered by -Region), runs the direct REST scan on each, and reports:
      - Phantom resources: visible via ARM REST but invisible to az resource list
      - Deleting RGs: resource groups stuck in the Deleting state

    With -OrphanScan: uses Azure Resource Graph (KQL) for efficient
    cross-subscription detection of orphaned resources:
      - Unattached managed disks, old snapshots, unused images
      - Orphaned NICs, public IPs, NSGs, route tables
      - Empty availability sets, load balancers with no backends
      - App Service Plans with no apps, orphaned NAT gateways
      - Orphaned private DNS zones, private endpoints
      - Azure Advisor cost recommendations

    This catches the same class of phantom resources as the single-RG mode but
    across the entire subscription. The -Region filter restricts which RGs are
    scanned (by RG location). Resources in the target region whose RG is located
    in a different region require running -SubScan without -Region.

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
    Subscription-wide phantom scan. Iterates all RGs (or only RGs in -Region)
    and applies the same direct REST scan as -ResourceGroup mode to each one.
    Reports phantom resources and RGs in Deleting state.
    Cannot be combined with -ResourceGroup.

.PARAMETER Region
    Azure region name (e.g. "centralindia"). In -SubScan mode: restricts scan
    to RGs located in this region and further filters resources by this location.
    Without -Region, all RGs in the subscription are scanned.

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

    Scans all RGs in centralindia for phantom resources and Deleting RGs.

.EXAMPLE
    pwsh find-phantom-resource.ps1 -SubScan

    Scans all RGs in the subscription for phantom resources. Use when the
    target resource may be in a region that differs from its RG location.

.EXAMPLE
    pwsh find-phantom-resource.ps1 -OrphanScan

    Uses Azure Resource Graph to find orphaned resources across the entire
    subscription: unattached disks, orphaned NICs, empty availability sets,
    App Service Plans with no apps, old snapshots, and more.

.EXAMPLE
    pwsh find-phantom-resource.ps1 -OrphanScan -SnapshotAgeDays 90

    Same as -OrphanScan but only flags snapshots older than 90 days.

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
    [switch]$DeleteResourceGroup,

    [Parameter(HelpMessage="Use Azure Resource Graph for efficient orphaned resource detection across subscription")]
    [switch]$OrphanScan,

    [Parameter(HelpMessage="Age threshold in days for snapshot orphan detection (default: 30)")]
    [int]$SnapshotAgeDays = 30
)

# Validate SnapshotAgeDays
if ($SnapshotAgeDays -lt 1) {
    Write-Host "ERROR: -SnapshotAgeDays must be at least 1." -ForegroundColor Red
    exit 1
}

# Validate parameter combinations
if ($OrphanScan -and ($SubScan -or $ResourceGroup)) {
    Write-Host "ERROR: -OrphanScan cannot be combined with -SubScan or -ResourceGroup." -ForegroundColor Red
    exit 1
}
if ($SubScan -and $ResourceGroup) {
    Write-Host "ERROR: -SubScan and -ResourceGroup are mutually exclusive." -ForegroundColor Red
    exit 1
}
if (-not $SubScan -and -not $ResourceGroup -and -not $OrphanScan) {
    Write-Host "ERROR: Provide -ResourceGroup <name>, -SubScan, or -OrphanScan." -ForegroundColor Red
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
    "Microsoft.MachineLearningServices/workspaces",
    "Microsoft.Compute/snapshots",
    "Microsoft.Compute/images"
)

# Resource types that are safe to delete when orphaned
$safeDeleteTypes = @(
    "Microsoft.Compute/disks",
    "Microsoft.Compute/availabilitySets",
    "Microsoft.Network/networkInterfaces",
    "Microsoft.Network/publicIPAddresses",
    "Microsoft.Network/virtualNetworks",
    "Microsoft.Network/networkSecurityGroups",
    "Microsoft.Network/routeTables",
    "Microsoft.Network/loadBalancers",
    "Microsoft.Network/natGateways",
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
        "Microsoft.Compute/snapshots" {
            $snap = Invoke-AzRest -Url "${ResourceId}?api-version=2024-03-02"
            if ($null -ne $snap) {
                # Snapshot is orphaned if its source disk no longer exists
                $sourceId = $snap.properties.creationData.sourceResourceId
                if ([string]::IsNullOrWhiteSpace($sourceId)) {
                    return $true
                }
                $sourceCheck = Invoke-AzRest -Url "${sourceId}?api-version=2024-03-02"
                if ($null -eq $sourceCheck) {
                    return $true  # Source disk no longer exists
                }
                # Also consider old snapshots (>$SnapshotAgeDays days) as candidates
                $timeCreated = $snap.properties.timeCreated
                if ($null -ne $timeCreated) {
                    try {
                        $created = [datetime]::Parse($timeCreated)
                        if ($created -lt (Get-Date).AddDays(-$SnapshotAgeDays)) {
                            return $true
                        }
                    } catch { }
                }
            }
            return $false
        }
        "Microsoft.Compute/availabilitySets" {
            $avset = Invoke-AzRest -Url "${ResourceId}?api-version=2024-07-01"
            if ($null -ne $avset) {
                $vms = $avset.properties.virtualMachines
                if ($null -eq $vms -or $vms.Count -eq 0) {
                    return $true
                }
            }
            return $false
        }
        "Microsoft.Compute/images" {
            # Custom VM images are orphaned if no VM references them
            # Since there is no direct back-reference, mark as orphaned only
            # if the source VM no longer exists
            $img = Invoke-AzRest -Url "${ResourceId}?api-version=2024-07-01"
            if ($null -ne $img) {
                $sourceVm = $img.properties.sourceVirtualMachine
                if ($null -ne $sourceVm -and -not [string]::IsNullOrWhiteSpace($sourceVm.id)) {
                    $vmCheck = Invoke-AzRest -Url "$($sourceVm.id)?api-version=2024-07-01"
                    if ($null -eq $vmCheck) {
                        return $true  # Source VM no longer exists
                    }
                }
            }
            return $false
        }
        "Microsoft.Network/natGateways" {
            $natgw = Invoke-AzRest -Url "${ResourceId}?api-version=2024-01-01"
            if ($null -ne $natgw) {
                $subnets = $natgw.properties.subnets
                if ($null -eq $subnets -or $subnets.Count -eq 0) {
                    return $true
                }
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
# ORPHANSCAN MODE: Azure Resource Graph orphaned resource scan
# ============================================================
if ($OrphanScan) {
    Write-Host "Orphaned Resource Scan via Azure Resource Graph" -ForegroundColor Cyan
    Write-Host "Requires: az extension 'resource-graph' (install with: az extension add --name resource-graph)`n"

    # Verify resource-graph extension
    $extCheck = az extension show --name resource-graph 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Installing resource-graph extension..." -ForegroundColor Yellow
        az extension add --name resource-graph --only-show-errors
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERROR: Failed to install resource-graph extension." -ForegroundColor Red
            exit 1
        }
    }

    $queries = [ordered]@{
        "Unattached Managed Disks" = @"
Resources
| where type =~ 'microsoft.compute/disks'
| where isempty(managedBy)
| extend diskState = tostring(properties.diskState)
| where diskState == 'Unattached'
| project name, resourceGroup, location, diskSizeGb=properties.diskSizeGB, sku=sku.name, subscriptionId
"@
        "Orphaned Network Interfaces" = @"
Resources
| where type =~ 'microsoft.network/networkinterfaces'
| where isempty(properties.virtualMachine)
| where isempty(properties.privateEndpoint)
| project name, resourceGroup, location, subscriptionId
"@
        "Unassociated Public IPs" = @"
Resources
| where type =~ 'microsoft.network/publicipaddresses'
| where isempty(properties.ipConfiguration)
| where isempty(properties.natGateway)
| project name, resourceGroup, location, sku=sku.name, ipAddress=properties.ipAddress, subscriptionId
"@
        "Unassociated NSGs" = @"
Resources
| where type =~ 'microsoft.network/networksecuritygroups'
| where isnull(properties.networkInterfaces) or array_length(properties.networkInterfaces) == 0
| where isnull(properties.subnets) or array_length(properties.subnets) == 0
| project name, resourceGroup, location, subscriptionId
"@
        "Load Balancers with No Backend" = @"
Resources
| where type =~ 'microsoft.network/loadbalancers'
| where array_length(properties.backendAddressPools) == 0
| project name, resourceGroup, location, sku=sku.name, subscriptionId
"@
        "Empty Availability Sets" = @"
Resources
| where type =~ 'microsoft.compute/availabilitysets'
| where array_length(properties.virtualMachines) == 0
| project name, resourceGroup, location, subscriptionId
"@
        "App Service Plans with No Apps" = @"
Resources
| where type =~ 'microsoft.web/serverfarms'
| where properties.numberOfSites == 0
| project name, resourceGroup, location, sku=sku.name, tier=sku.tier, subscriptionId
"@
        "Unassociated Route Tables" = @"
Resources
| where type =~ 'microsoft.network/routetables'
| where isnull(properties.subnets) or array_length(properties.subnets) == 0
| project name, resourceGroup, location, subscriptionId
"@
        "Orphaned Snapshots (>$SnapshotAgeDays days)" = @"
Resources
| where type =~ 'microsoft.compute/snapshots'
| extend timeCreated = todatetime(properties.timeCreated)
| where timeCreated < ago(${SnapshotAgeDays}d)
| project name, resourceGroup, location, diskSizeGb=properties.diskSizeGB, timeCreated, subscriptionId
"@
        "Orphaned NAT Gateways" = @"
Resources
| where type =~ 'microsoft.network/natgateways'
| where isnull(properties.subnets) or array_length(properties.subnets) == 0
| project name, resourceGroup, location, subscriptionId
"@
        "Orphaned Private DNS Zones" = @"
Resources
| where type =~ 'microsoft.network/privatednszones'
| where properties.numberOfVirtualNetworkLinks == 0
| project name, resourceGroup, location, subscriptionId
"@
        "Advisor Cost Recommendations" = @"
AdvisorResources
| where properties.category == 'Cost'
| project name, impact=properties.impact, description=properties.shortDescription.solution, resourceId=properties.resourceMetadata.resourceId
"@
    }

    $totalOrphans = 0
    foreach ($queryName in $queries.Keys) {
        Write-Host "`n=== $queryName ===" -ForegroundColor Cyan
        $kql = $queries[$queryName]
        try {
            $allData = [System.Collections.Generic.List[object]]::new()
            $skipToken = $null
            $pageNum = 0
            $maxPages = 10  # Safety limit

            do {
                $pageNum++
                $graphArgs = @("graph", "query", "-q", $kql, "--first", "200", "-o", "json", "--only-show-errors")
                if ($skipToken) {
                    $graphArgs += @("--skip-token", $skipToken)
                }
                $resultJson = & az @graphArgs 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "  Query failed: $resultJson" -ForegroundColor Red
                    break
                }
                $result = $resultJson | ConvertFrom-Json
                if ($null -ne $result.data) {
                    foreach ($item in $result.data) { $allData.Add($item) }
                }
                $skipToken = $result.'$skipToken'
            } while ($skipToken -and $pageNum -lt $maxPages)

            if ($allData.Count -gt 0) {
                $totalOrphans += $allData.Count
                Write-Host "  Found $($allData.Count) orphaned resource(s):" -ForegroundColor Yellow
                $allData | Format-Table -AutoSize
            } else {
                Write-Host "  None found." -ForegroundColor Green
            }
        } catch {
            Write-Host "  Error: $_" -ForegroundColor Red
        }
    }

    Write-Host "`n=============================================" -ForegroundColor Cyan
    if ($totalOrphans -gt 0) {
        Write-Host "Total orphaned resources found: $totalOrphans" -ForegroundColor Yellow
        Write-Host "Review each category above before deleting." -ForegroundColor Yellow
    } else {
        Write-Host "No orphaned resources found." -ForegroundColor Green
    }
    exit 0
}

# ============================================================
# SUBSCAN MODE: subscription-wide phantom scan per RG
# ============================================================
if ($SubScan) {
    $subscriptionId = az account show --query id -o tsv
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Failed to get subscription ID." -ForegroundColor Red
        exit 1
    }

    $regionLabel = if ($Region) { $Region } else { "all regions" }
    Write-Host "Subscription-wide phantom scan: $regionLabel" -ForegroundColor Cyan
    Write-Host "Subscription: $subscriptionId`n"

    # List resource groups, optionally filtered by location.
    # JMESPath location== is case-sensitive, so fetch all RGs and filter in PowerShell
    # with -ieq to handle mixed-case input (e.g. "CentralIndia" vs "centralindia").
    # Note: -Region filters by RG location. Resources in the target region whose
    # RG is located elsewhere require running without -Region to be found.
    Write-Host "  Listing resource groups..." -NoNewline
    $rgListJson = az group list -o json --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host " FAILED" -ForegroundColor Red
        Write-Host "ERROR: az group list failed. Check authentication." -ForegroundColor Red
        exit 1
    }
    try {
        $rgListAll = $rgListJson | ConvertFrom-Json
        $rgList = if ($Region) { @($rgListAll | Where-Object { $_.location -ieq $Region }) } else { $rgListAll }
    } catch {
        Write-Host " FAILED (parse error: $_)" -ForegroundColor Red
        exit 1
    }
    Write-Host " $($rgList.Count) found"

    if ($rgList.Count -eq 0) {
        Write-Host "No resource groups found for the specified filter." -ForegroundColor Yellow
        exit 0
    }

    $allPhantoms  = [System.Collections.Generic.List[object]]::new()
    $deletingRGs  = [System.Collections.Generic.List[object]]::new()
    $skippedRGs   = [System.Collections.Generic.List[string]]::new()
    $scannedCount = 0

    foreach ($rg in $rgList) {
        $rgName  = $rg.name
        $rgState = $rg.properties.provisioningState
        $scannedCount++

        Write-Host "  [$scannedCount/$($rgList.Count)] $rgName ($rgState)..." -NoNewline

        if ($rgState -eq "Deleting") {
            $deletingRGs.Add($rg)
        }

        # Direct REST scan - same reliable method as single-RG mode.
        # Bypasses JMESPath casing bug and finds phantoms invisible to az resource list.
        # Paginates via nextLink so large RGs are fully covered.
        # No secondary resource-location filter: the RG list was already scoped to
        # -Region, so all resources in those RGs are relevant regardless of their
        # individual location field.
        $items = [System.Collections.Generic.List[object]]::new()
        $nextUrl = "/subscriptions/$subscriptionId/resourceGroups/$rgName/resources?api-version=2024-03-01"
        $restFailed = $false
        while ($nextUrl) {
            $restResult = Invoke-AzRest -Url $nextUrl
            if ($null -eq $restResult -or $null -eq $restResult.value) {
                Write-Host " (REST failed, skipped)"
                $skippedRGs.Add("$rgName (REST)")
                $restFailed = $true
                break
            }
            foreach ($item in $restResult.value) { $items.Add($item) }
            $nextUrl = $restResult.nextLink
        }
        if ($restFailed) { continue }

        if ($items.Count -eq 0) {
            Write-Host " (no resources)"
            continue
        }

        # az resource list for comparison - may miss phantoms due to casing mismatch.
        # Skip this RG if az resource list fails or parse fails: an empty baseline
        # would flag every REST-visible resource as phantom (false positives).
        $azListJson = az resource list -g $rgName -o json --only-show-errors 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host " (az resource list failed, skipped)"
            $skippedRGs.Add("$rgName (az resource list)")
            continue
        }
        $azIds = @{}
        try {
            $azParsed = $azListJson | ConvertFrom-Json
            foreach ($r in $azParsed) { $azIds[$r.id.ToLower()] = $true }
        } catch {
            Write-Warning "Failed to parse 'az resource list' for '$rgName'. Phantom detection skipped for this RG."
            $skippedRGs.Add("$rgName (az resource list parse)")
            continue
        }

        # Find phantoms: in direct REST but not in az resource list.
        $rgPhantoms = 0
        foreach ($r in $items) {
            if (-not $azIds.ContainsKey($r.id.ToLower())) {
                $allPhantoms.Add([PSCustomObject]@{
                    Name          = $r.name
                    Type          = $r.type
                    Location      = $r.location
                    ResourceGroup = $rgName
                    RgStatus      = $rgState
                    Id            = $r.id
                })
                $rgPhantoms++
            }
        }

        $phantomNote = if ($rgPhantoms -gt 0) { " [$rgPhantoms PHANTOM]" } else { "" }
        Write-Host " $($items.Count) resource(s)$phantomNote"
    }

    Write-Host ""

    # Report Deleting RGs
    if ($deletingRGs.Count -gt 0) {
        Write-Host "=== Resource Groups in Deleting State ===" -ForegroundColor Yellow
        foreach ($rg in $deletingRGs) {
            Write-Host "  [DELETING] $($rg.name) ($($rg.location))" -ForegroundColor Yellow
        }
        Write-Host ""
    }

    # Report phantom resources
    if ($allPhantoms.Count -eq 0) {
        Write-Host "No phantom resources found." -ForegroundColor Green
    } else {
        Write-Host "=== Phantom Resources (invisible to 'az resource list') ===" -ForegroundColor Yellow
        Write-Host "  Found $($allPhantoms.Count) phantom resource(s):" -ForegroundColor Yellow
        $allPhantoms | Format-Table Name, Type, Location, ResourceGroup, RgStatus -AutoSize
        Write-Host "  Resource IDs:" -ForegroundColor Yellow
        foreach ($p in $allPhantoms) {
            Write-Host "    [$($p.RgStatus)] $($p.Id)"
        }
        Write-Host ""
        Write-Host "  To delete via REST:" -ForegroundColor Cyan
        Write-Host "    az rest --method DELETE --url 'https://management.azure.com/<full-resource-id>?api-version=...'" -ForegroundColor Cyan
        Write-Host "    where <full-resource-id> starts with /subscriptions/..." -ForegroundColor Cyan
    }

    if ($skippedRGs.Count -gt 0) {
        Write-Warning "Scan incomplete - the following RG(s) were skipped due to errors:"
        foreach ($s in $skippedRGs) {
            Write-Warning "  $s"
        }
        Write-Host "`nPartial scan complete. Scanned $scannedCount RG(s), skipped $($skippedRGs.Count)." -ForegroundColor Yellow
        exit 2
    }

    Write-Host "`nScan complete. Scanned $scannedCount RG(s)." -ForegroundColor Green
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
                "Microsoft.Compute/snapshots",
                "Microsoft.Compute/images",
                "Microsoft.Compute/availabilitySets",
                "Microsoft.Network/networkInterfaces",
                "Microsoft.Network/publicIPAddresses",
                "Microsoft.Network/loadBalancers",
                "Microsoft.Network/natGateways",
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
