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

.PARAMETER ResourceGroup
    Name of the Azure resource group to scan.

.EXAMPLE
    pwsh find-phantom-resource.ps1 -ResourceGroup "FishtestSpotRG-10"

    Scans FishtestSpotRG-10 for phantom resources and prints resource IDs.

.EXAMPLE
    pwsh find-phantom-resource.ps1 -ResourceGroup "MyRG"

    After finding resources, delete them and the RG:
      az resource delete --ids "<resource-id-from-output>"
      az group delete -n "MyRG" --yes

.NOTES
    Requires: Azure CLI (az) authenticated and with an active subscription.
#>

param(
    [Parameter(Mandatory=$true, HelpMessage="Name of the Azure resource group to scan")]
    [string]$ResourceGroup
)

Write-Host "Scanning for phantom resources in RG: $ResourceGroup" -ForegroundColor Cyan

# 0. REST API direct query - most reliable method.
# Queries ARM by resource group path, bypassing case-sensitive JMESPath filtering.
# This is the only method guaranteed to find all resources.
Write-Host "`n=== REST API Direct Query (most reliable) ==="
$subscriptionId = az account show --query id -o tsv
$restUrl = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/resources?api-version=2024-03-01"
$restResult = az rest --method GET --url $restUrl 2>&1
if ($LASTEXITCODE -eq 0) {
    $parsed = $restResult | ConvertFrom-Json
    if ($parsed.value.Count -gt 0) {
        Write-Host "  Found $($parsed.value.Count) resource(s) via REST API:" -ForegroundColor Yellow
        $parsed.value | Format-Table name, type, location -AutoSize
        Write-Host "`n  Resource IDs (use 'az resource delete --ids <id>' to remove):" -ForegroundColor Yellow
        foreach ($r in $parsed.value) {
            Write-Host "    $($r.id)"
        }
    } else {
        Write-Host "  No resources found via REST API"
    }
} else {
    Write-Host "  REST API query failed: $restResult" -ForegroundColor Red
}

# 1. Generic ARM resources (may miss resources with casing mismatch)
Write-Host "`n=== ARM Resources (az resource list) ==="
az resource list -g $ResourceGroup -o table

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

Write-Host "`nScan complete." -ForegroundColor Green
