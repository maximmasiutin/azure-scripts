# Introduction - Useful Scripts for Microsoft Azure

1. **monitor-eviction.py**: Monitors a spot VM to determine whether it is being evicted and stops a Linux service before the VM instance is stopped.
1. **vm-spot-price.py**: Returns a sorted list (by VM instance spot price) of Azure regions to find cheapest spot instance price. Supports multi-VM comparison, per-core pricing analysis, and Windows VMs. Examples of use:
  `python vm-spot-price.py --cpu 4 --sku-pattern "B#s_v2"` (~1 page)
  `python vm-spot-price.py --vm-sizes "D4pls_v5,D4ps_v5,F4s_v2,D4as_v5" --return-region` (~4 pages)
  `python vm-spot-price.py --cpu 64 --no-burstable --region eastus` (~4 pages)
  `python vm-spot-price.py --min-cores 2 --max-cores 64 --general-compute --return-region` (~130 pages)
  `python vm-spot-price.py --all-vm-series --cpu 64` (~140 pages)
  `python vm-spot-price.py --windows --cpu 4 --sku-pattern "B#s_v2"` (~1 page, Windows)  
1. **blob-storage-price.py**: Returns Azure regions sorted by average blob storage price (page/block, premium/general, etc.) to find cheapest cloud storage price. Examples of use:  
  `python blob-storage-price.py`  
  `python blob-storage-price.py --blob-types "General Block Blob v2"`  
  `python blob-storage-price.py --blob-types "General Block Blob v2, Premium Block Blob"`  

1. **create-spot-vms.ps1**: Creates Azure Spot VMs with full ARM64 support. Auto-detects latest Ubuntu minimal image based on CPU architecture (ARM64 Cobalt/Ampere or x64 AMD/Intel).
1. **create-192core-vm.ps1**: Creates a 192-core Azure Spot VM. Auto-finds cheapest VM size and region, checks quota in 40 regions before querying prices, excludes restricted regions. Shows progress indicator.
1. **set-storage-account-content-headers.ps1**: Sets Azure static website files content headers (such as Content-Type or Cache-Control).
1. **register-preview-features.ps1**: Manages Azure preview feature flags. Lists, registers, unregisters, and exports feature states. Useful for enabling new VM series (v7 Turin) that require feature flag registration.
1. **monitor-stddev.py**: A stability-focused website monitor that uses standard deviation of latency to detect jitter and performance degradation, not just outages. Publishes results to Azure/local files. See [monitor-stddev.md](monitor-stddev.md).
1. **azure-swap.bash**: A tool that looks for local temporary disk and creates a swap file of 90% of that storage, leaving 10% available. It creates an autostart server in case of Azure removed the disk if machine was stopped.  


# Details 
A collection of Python and PowerShell utilities for Azure cost optimization, monitoring, and automation.
## Core Utilities
### Cost Optimization Scripts

1. **vm-spot-price.py**: Find the cheapest Azure regions for spot VM instances
   - Key Features: Multi-region price comparison, custom CPU/SKU filtering, spot vs regular pricing
   - Multi-VM Comparison: Compare multiple VM sizes at once with `--vm-sizes` parameter
   - **Per-Core Pricing**: Find cheapest spot price per vCPU core across VM series with `--min-cores` and `--max-cores`
   - **ARM VM Support**: Supports ARM-based VMs (e.g., D4ps_v5, D4pls_v5) with automatic detection and proper Azure API querying
   - **Windows VM Support**: Use `--windows` to search for Windows VMs instead of Linux (default). Windows VMs typically cost 8-15% more due to OS license fees.
   - Exclusion Filters: Exclude specific regions, VM sizes, SKU patterns (# = digits), or ARM VMs via `--exclude-arm`
   - Advanced Options: Series pattern matching, non-spot instance filtering, single region output
   - **Quality Filtering**: Automatically filters out invalid or zero-price (free tier) instances to ensure valid spot pricing.
   - PowerShell Integration: `--return-region` outputs "region vmsize price unit" format; `--return-region-json` outputs JSON for direct parsing
   - Use Cases: Cost optimization before VM deployment, automated region selection
   - **Progress Display**: Shows "Fetching page N/M (ETA: Xs)" with real-time ETA calculation based on actual fetch times
   - **API Efficiency**: Different query modes use different numbers of API pages:
     - SKU pattern mode: ~1 page per SKU (fastest)
     - Multi-VM mode (`--vm-sizes`): ~1 page per VM size
     - Multi-query mode (`--series`, `--latest`): ~2 pages per series
     - Single-query mode (`--no-burstable`, `--general-compute`): ~4 pages/region, ~130 pages all regions
     - All-VM mode (`--all-vm-series`): ~5 pages/region, ~140 pages all regions
     - Use `--region` to reduce pages from ~130-140 to ~4-5
   - Examples:
     ```bash
     # Single SKU pattern (1 page)
     python vm-spot-price.py --cpu 4 --sku-pattern "B#s_v2"
     python vm-spot-price.py --sku-pattern "B4ls_v2" --series-pattern "Bsv2" --return-region

     # Multi-VM comparison (1 page per VM size)
     python vm-spot-price.py --vm-sizes "D4pls_v5,D4ps_v5,F4s_v2,D4as_v5" --return-region

     # Per-core pricing - single query mode (~4 pages with --region, ~130 without)
     python vm-spot-price.py --cpu 64 --no-burstable --region eastus        # ~4 pages
     python vm-spot-price.py --cpu 64 --no-burstable                        # ~130 pages
     python vm-spot-price.py --min-cores 2 --max-cores 64 --general-compute # ~130 pages

     # Per-core pricing - multi-query mode (1 page per series)
     python vm-spot-price.py --min-cores 4 --max-cores 32 --latest --return-region  # 29 series
     python vm-spot-price.py --min-cores 2 --max-cores 16 --series "Dasv6,Fasv7"    # 2 series

     # Per-core filtering options
     # --general-compute: Only D+F series, single query (~4 pages/region)
     # --latest: Only v6/v7 series, multi-query (1 page per 29 series)
     # --no-burstable: Exclude B-series, single query (~4 pages/region)
     # --burstable-only: Only B-series, single query (~4 pages/region)
     # --series: Specific series list, multi-query (1 page per series)

     # ARM-based VMs (Ampere Altra processors) - automatic detection
     python vm-spot-price.py --vm-sizes "D4pls_v5,D4ps_v5" --return-region  # ~2 pages (ARM VMs)
     python vm-spot-price.py --min-cores 4 --max-cores 16 --exclude-arm     # ~130 pages

     # Windows VMs (default is Linux) - typically 8-15% more expensive
     python vm-spot-price.py --windows --cpu 4 --sku-pattern "B#s_v2"                   # ~1 page
     python vm-spot-price.py --windows --vm-sizes "D4as_v5,F4s_v2" --return-region      # ~2 pages
     python vm-spot-price.py --windows --cpu 64 --no-burstable --region eastus          # ~4 pages
     python vm-spot-price.py --windows --min-cores 2 --max-cores 64 --general-compute   # ~130 pages

     # All VM series mode (no series filter - discovers all available VMs)
     python vm-spot-price.py --all-vm-series --region eastus                            # ~5 pages
     python vm-spot-price.py --all-vm-series --cpu 64                                   # ~140 pages
     python vm-spot-price.py --all-vm-series --cpu 64 --windows --region westus2        # ~5 pages

     # Exclude specific regions or VM sizes
     python vm-spot-price.py --vm-sizes "D4pls_v5,D4ps_v5" --exclude-regions "centralindia,eastasia"  # ~2 pages
     python vm-spot-price.py --vm-sizes "D4pls_v5,D4ps_v5" --exclude-regions-file regions1.txt        # ~2 pages

     # Exclude by SKU pattern (# = digits wildcard)
     python vm-spot-price.py --min-cores 4 --max-cores 64 --exclude-sku-patterns "D#ps_v6,D#pds_v6"  # ~130 pages
     # Excludes D4ps_v6, D8ps_v6, D16ps_v6, etc. and all Dpds_v6 variants

     # PowerShell integration (text output)
     # $result = python vm-spot-price.py --min-cores 2 --max-cores 64 --general-compute --return-region
     # $region, $vmSize, $price, $unit = $result -split ' ', 4

     # PowerShell integration (JSON output - recommended)
     # $json = python vm-spot-price.py --vm-sizes "D4as_v5,F4s_v2" --return-region-json | ConvertFrom-Json
     # New-AzVM -Location $json.region -Size $json.vmSize -Priority Spot ...
     ```

2. **blob-storage-price.py**: Compare Azure blob storage pricing across regions
   - Key Features: Automatic price aggregation across storage types, region-based cost analysis
   - Storage Types Supported: Standard Page Blob, General Block Blob, Premium Block Blob, and more
   - Output: Sorted pricing table with average costs per region
   - Examples:
     ```bash
     python blob-storage-price.py
     python blob-storage-price.py --blob-types "General Block Blob v2"
     python blob-storage-price.py --blob-types "General Block Blob v2, Premium Block Blob"
     ```

### Monitoring and Reliability Scripts

3. **monitor-eviction.py**: Graceful handling of Azure spot VM evictions
   - Key Features: Real-time eviction detection via Azure Metadata Service, configurable service shutdown
   - Safety Features: Service validation, custom hook execution, Azure environment detection
   - Integration: Works as systemd service or container, supports custom shutdown scripts
   - Critical Use Case: Prevents data loss during spot VM evictions by gracefully stopping services
   - Usage:
     ```bash
     ./monitor-eviction.py --stop-services nginx,postgresql --hook /path/to/backup-script.sh
     ```

4. **monitor-stddev.py**: Comprehensive website health monitoring with statistical analysis
   - Advanced Metrics: Latency standard deviation, error rate tracking, health status determination
   - Storage Options: Local files, Azure Blob Storage, Azure Cosmos DB Table API
   - Visualization: Automatic HTML reports, PNG history graphs, real-time status pages
   - Enterprise Features: Persistent HTTP sessions, custom authorization headers, timezone support
   - Statistical Analysis: Uses standard deviation thresholds to detect performance anomalies
   - See [monitor-stddev.md](monitor-stddev.md) for comprehensive documentation

### Infrastructure Management Scripts

5. **create-192core-vm.ps1**: High-core-count spot VM deployment
   - Purpose: Creates a 192-core Azure Spot VM with automatic region and VM size selection
   - Pre-flight Quota Check: Checks spot quota in 40 regions before querying prices
   - Auto-detection: Finds cheapest 192-core VM across regions with available quota
   - Exclusions: Filters out restricted regions and Extended Zone city names
   - Progress Display: Shows progress while querying Azure Retail Prices API (~130 pages)
   - Usage: `pwsh ./create-192core-vm.ps1 [-VMName "name"] [-WhatIf]`

6. **create-spot-vms.ps1**: Automated spot VM deployment with ARM64 support
   - **Full ARM64 Support**: Native support for ARM-based Azure VMs (Cobalt 100, Ampere Altra)
     - ARM VMs (D*p*_v5, D*p*_v6) automatically detected and use ARM64 Ubuntu images
     - Competitive spot pricing for ARM VMs in many regions
   - **Automatic Ubuntu Image Detection**: Queries Azure API for newest available Ubuntu
     - Default: Latest non-LTS Ubuntu minimal (25.10) - smaller, faster boot
     - Minimal images preferred over full server images
     - Use `-UseLTS` to prefer LTS versions (24.04) for production workloads
     - Use `-PreferServer` to use full server image instead of minimal
   - Features: Batch creation of multiple spot instances with consistent configuration
   - Cost Optimization: Leverages spot pricing for development/testing environments
   - **Quota Checks**: Pre-flight checks for both Spot vCPU quota and Public IP quota
     - Spot vCPU quota: Checks `lowPriorityCores` limit before VM creation
     - Public IP quota: Checks `StandardPublicIPAddresses` limit (default: 20/region)
     - Use `-RequestQuota` to auto-create Azure Support ticket for quota increase
     - Use `-NoPublicIP -UseNatGateway` to avoid IP quota limits (1 IP for all VMs)
   - **Custom Initialization**: Supports passing cloud-init scripts via `-CustomData` or downloading from `-InitScriptUrl`.
   - **Network Flexibility**: Supports `-NoPublicIP` (default: creates public IP) and `-UseNatGateway`.
   - **Resiliency**: Auto-detects supported regions and blacklists specific VM sizes if unavailable. Robust error handling ensures stability.
   - **Clean Logs**: Automatically suppresses Azure PowerShell breaking change warnings to reduce noise.
   - **Force Overwrite**: Use `-ForceOverwrite` switch to suppress interactive prompts when overwriting existing resources (useful for automation).
   - **Infrastructure-Only Mode**: Use `-CreateInfrastructureOnly` with `-UseNatGateway` to create only shared infrastructure (RG, VNet, NAT Gateway) without VMs. Returns JSON with resource details. Useful for multi-worker orchestration where infrastructure should be created once before spawning parallel workers.

7. **set-storage-account-content-headers.ps1**: Static website optimization and deployment
   - Purpose: Configure proper Content-Type and Cache-Control headers for Azure static websites
   - Upload Feature: Optionally upload local files to Azure Blob Storage with `-LocalFilePath` parameter
   - Performance: Improves website loading times and SEO through proper HTTP headers
   - Usage:
     ```powershell
     # Set headers on existing blobs
     pwsh ./set-storage-account-content-headers.ps1 -BlobSasUrl "https://..." -CacheControl "public, max-age=432000"

     # Upload file and set headers
     pwsh ./set-storage-account-content-headers.ps1 -BlobSasUrl "https://..." -LocalFilePath "C:\path\to\file.html" -CacheControl "public, max-age=432000" -ContentType "text/html; charset=utf-8"

     # Upload only (no header changes)
     pwsh ./set-storage-account-content-headers.ps1 -BlobSasUrl "https://..." -LocalFilePath "C:\path\to\file.html"
     ```

8. **azure-swap.bash**: Dynamic SWAP provisioning for Azure VMs with temporary storage
   - Key Features: Automatically detects Azure "Temporary Storage" partitions, uses 90% for swap files
   - Resilience: Handles ephemeral storage by recreating swap on each boot via systemd service
   - Fallback: Creates 2GB+ swap in /mnt if no temporary storage found
   - Security: Comprehensive input validation, privilege checks, and secure file operations
   - Benefits: Optimizes memory usage on VMs with local SSDs that reset on stop/start
   - Usage:
     ```bash
     sudo ./azure-swap.bash
     sudo systemctl status robust-swap-setup.service
     ```

## Prerequisites

**Python Requirements:**
- Python 3.6+
- Required packages: `curl_cffi`, `tabulate`, `azure-storage-blob`, `azure-data-tables`, `Pillow`

**PowerShell Requirements:**
- PowerShell 7.5 or later (run scripts with `pwsh`)
- Azure PowerShell module (Az)
- Appropriate Azure subscription permissions

**Bash Requirements:**
- systemd-based Linux distribution (Ubuntu, RHEL, SUSE, etc.)
- Root privileges for swap configuration
- Standard utilities: `systemctl`, `blkid`, `mount`, `dd`, `mkswap`, `swapon`

**Installation:**
```bash
# Via pip (recommended)
pip install curl_cffi tabulate azure-storage-blob azure-data-tables Pillow
```

Note: `curl_cffi` replaces `requests` for browser-like TLS fingerprinting (avoids Cloudflare bot detection).

## Quick Start Examples

**Find cheapest region for a specific VM (1 page):**
```bash
python vm-spot-price.py --sku-pattern "B4ls_v2" --return-region
```

**Find cheapest spot option across multiple VM sizes (1 page per VM):**
```bash
python vm-spot-price.py --vm-sizes "D4pls_v5,D4ps_v5,F4s_v2,D4as_v5,D4s_v5" --return-region
# Output: centralindia Standard_D4as_v5
```

**Find cheapest spot price per core - fast with region filter (~4 pages):**
```bash
python vm-spot-price.py --cpu 64 --no-burstable --region eastus --return-region
# Output: eastus Standard_D64pls_v6 0.3849 1 Hour
```

**Find cheapest spot price per core - all regions (~130 pages):**
```bash
python vm-spot-price.py --min-cores 2 --max-cores 64 --general-compute --return-region
# Output: newzealandnorth Standard_F32ams_v6 0.066343 1 Hour
```

**Monitor website with Azure integration:**
```bash
python monitor-stddev.py --url "https://example.com" \
  --azure-blob-storage-connection-string "your_connection_string" \
  --azure-blob-storage-container-name '$web'
```

**Set up spot VM eviction monitoring:**
```bash
./monitor-eviction.py --stop-services "apache2,mysql" --hook "/opt/backup.sh"
```

**Configure dynamic swap for Azure VMs:**
```bash
sudo ./azure-swap.bash
# Verify service is running
sudo systemctl status robust-swap-setup.service
```

**Create Azure spot VMs (PowerShell 7.5+):**
```powershell
# Run with pwsh (PowerShell 7.5+)
# Default: auto-detects latest Ubuntu (25.10 minimal) - ideal for spot VMs
pwsh ./create-spot-vms.ps1 -Location "eastus" -VMSize "Standard_D4as_v5" -VMName "myvm"

# ARM VM with auto-detected ARM64 Ubuntu minimal image
pwsh ./create-spot-vms.ps1 -Location "centralindia" -VMSize "Standard_D64pls_v6" -VMName "arm-vm"

# Use LTS Ubuntu (24.04) for production workloads
pwsh ./create-spot-vms.ps1 -Location "eastus" -VMSize "Standard_D4as_v5" -VMName "myvm" -UseLTS

# Prefer full server image over minimal
pwsh ./create-spot-vms.ps1 -Location "eastus" -VMSize "Standard_D4as_v5" -VMName "myvm" -PreferServer
```

## Advanced Features

- **Cost Analytics**: Historical price tracking and trend analysis
- **Multi-cloud Readiness**: Designed patterns that can extend to other cloud providers
- **Enterprise Integration**: Support for Azure AD authentication, Cosmos DB, and Blob Storage
- **Monitoring Standards**: Statistical health analysis using standard deviation metrics
- **Automation Ready**: All scripts support automation and CI/CD integration

## Use Cases

- **DevOps**: Automated cost optimization and infrastructure monitoring
- **FinOps**: Cloud cost analysis and budget optimization
- **SRE**: Website reliability monitoring with statistical analysis
- **Development**: Spot instance management for cost-effective development environments

## Troubleshooting

### Ephemeral Public IPs and Spot VMs

**Spot VMs cannot use ephemeral public IPs.** This is an Azure platform limitation:

1. Ephemeral public IPs require ephemeral OS disks
2. Spot VMs do not support ephemeral OS disks
3. Therefore, Spot VMs must use Standard SKU public IPs (separate ARM resources)

The script creates public IPs with `deleteOption=Delete`, ensuring automatic cleanup when VMs are deleted or evicted. However, each public IP:
- Costs ~$3.65/month
- Counts against the StandardPublicIPAddresses quota (default: 20 per region)

**Alternatives for Spot workloads:**
- **NAT Gateway**: Shared outbound IP for all VMs (~$37/month total)
- **No public IP**: Private network access via jumpbox or VPN

### Public IP Quota Errors

Azure has a default limit of **20 Standard Public IPs per region per subscription**. When this limit is reached, you may see "ResourceNotFound" errors during IP creation - this is actually a masked quota exhaustion error, not a missing resource.

**Symptoms:**
- `ResourceNotFound` errors when creating Public IPs
- VM creation fails after VNet/Subnet succeed
- `QuotaExceeded` or `OperationNotAllowed` errors

**Check IP quota manually:**

PowerShell:
```powershell
Get-AzNetworkUsage -Location "eastus" | Where-Object { $_.Name.Value -eq "StandardPublicIPAddresses" }
```

Azure CLI:
```bash
az network list-usages --location eastus --query "[?contains(name.value, 'StandardPublicIPAddresses')]"
```

**Solutions:**

1. **Request quota increase** - Via Azure Portal > Quotas > Networking, or use `-RequestQuota` switch with create-spot-vms.ps1

2. **Use NAT Gateway** - One IP for multiple VMs: `pwsh ./create-spot-vms.ps1 -NoPublicIP -UseNatGateway`
   - Cost: ~$33/month vs ~$77/month for 21 individual IPs

3. **Clean orphaned IPs** - Unattached IPs consume quota:
   ```powershell
   # List orphaned IPs
   Get-AzPublicIpAddress -ResourceGroupName "MyRG" | Where-Object { $null -eq $_.IpConfiguration }
   # Delete them
   Get-AzPublicIpAddress -ResourceGroupName "MyRG" | Where-Object { $null -eq $_.IpConfiguration } | Remove-AzPublicIpAddress -Force
   ```

4. **Skip public IPs** - For VMs that only need outbound: `pwsh ./create-spot-vms.ps1 -NoPublicIP`

### NAT Gateway Architecture (Cost-Effective Alternative)

For deployments with many VMs, using NAT Gateway instead of individual Public IPs can significantly reduce costs.

**What is NAT Gateway?**
- Azure NAT Gateway provides outbound internet connectivity for VMs without individual public IPs
- All VMs in the subnet share one public IP for outbound traffic
- Inbound connections are not possible (no public IP on VMs) - use jumpbox or VPN for SSH

**Architecture:**
```
Internet
    |
    v
[NAT Gateway] <-- 1 Public IP (~$3.65/month)
    |              + ~$32.85/month NAT Gateway fee
    v              + $0.045/GB data processed
[VNet/Subnet]
    |
    +-- VM1 (private IP: 10.0.0.4)
    +-- VM2 (private IP: 10.0.0.5)
    +-- ...
    +-- VM20 (private IP: 10.0.0.23)
    |
[Jumpbox VM] <-- 1 Public IP for SSH access (optional)
```

**Cost Comparison:**
| VMs | Individual Public IPs | NAT Gateway | Savings |
|-----|----------------------|-------------|---------|
| 5 VMs | ~$18/month | ~$37/month | -$19 (NAT more expensive) |
| 10 VMs | ~$37/month | ~$37/month | Break-even |
| 20 VMs | ~$73/month | ~$37/month | +$36/month |
| 50 VMs | ~$183/month | ~$37/month | +$146/month |

NAT Gateway becomes cost-effective at 10+ VMs per region.

**Creating VMs with NAT Gateway:**

```powershell
# Single VM with NAT Gateway
pwsh ./create-spot-vms.ps1 -Location "eastus" -VMSize "Standard_D4as_v5" `
    -VMName "worker1" -ResourceGroupName "MyRG" -NoPublicIP -UseNatGateway

# Multiple VMs sharing the same NAT Gateway (same ResourceGroup = same VNet = shared NAT)
pwsh ./create-spot-vms.ps1 -Location "eastus" -VMSize "Standard_D64as_v5" `
    -VMName "worker1" -ResourceGroupName "WorkersRG" -NoPublicIP -UseNatGateway

pwsh ./create-spot-vms.ps1 -Location "eastus" -VMSize "Standard_D64as_v5" `
    -VMName "worker2" -ResourceGroupName "WorkersRG" -NoPublicIP -UseNatGateway

# First VM creates: VNet, Subnet, NAT Gateway, NAT Gateway Public IP
# Subsequent VMs in same RG reuse existing NAT Gateway

# Infrastructure-only mode (for multi-worker orchestration)
# Create shared infrastructure first, then spawn workers in parallel
pwsh ./create-spot-vms.ps1 -Location "eastus" -ResourceGroupName "WorkersRG" `
    -UseNatGateway -NoPublicIP -CreateInfrastructureOnly
# Returns JSON: {"Success":true,"ResourceGroupName":"WorkersRG","VNetName":"MyNet",
#   "NatGatewayName":"MyNet-natgw","NatGatewayPublicIP":"20.xx.xx.xx",...}
```

**What gets created:**
```
ResourceGroup (e.g., WorkersRG)
  |
  +-- MyNet (VNet: 10.0.0.0/16)
  |     +-- MySubnet (10.0.0.0/24) --> associated with NAT Gateway
  |
  +-- MyNet-natgw (NAT Gateway, Standard SKU)
  +-- MyNet-natgw-pip (Public IP for NAT Gateway)
  |
  +-- worker1 (VM, private IP only)
  +-- worker1-nic (NIC)
  +-- worker1-osdisk (OS Disk)
  |
  +-- worker2 (VM, private IP only)
  +-- worker2-nic (NIC)
  +-- worker2-osdisk (OS Disk)
```

**Deleting NAT Gateway and VMs:**

```powershell
# Delete entire Resource Group (recommended - cleanest)
Remove-AzResourceGroup -Name "WorkersRG" -Force

# Or delete individual resources manually:
# 1. Delete VMs first
Remove-AzVM -ResourceGroupName "WorkersRG" -Name "worker1" -Force
Remove-AzVM -ResourceGroupName "WorkersRG" -Name "worker2" -Force

# 2. Delete NICs
Remove-AzNetworkInterface -ResourceGroupName "WorkersRG" -Name "worker1-nic" -Force
Remove-AzNetworkInterface -ResourceGroupName "WorkersRG" -Name "worker2-nic" -Force

# 3. Delete OS disks
Remove-AzDisk -ResourceGroupName "WorkersRG" -DiskName "worker1-osdisk" -Force
Remove-AzDisk -ResourceGroupName "WorkersRG" -DiskName "worker2-osdisk" -Force

# 4. Disassociate NAT Gateway from subnet before deletion
$vnet = Get-AzVirtualNetwork -ResourceGroupName "WorkersRG" -Name "MyNet"
Set-AzVirtualNetworkSubnetConfig -VirtualNetwork $vnet -Name "MySubnet" `
    -AddressPrefix "10.0.0.0/24" -NatGateway $null | Out-Null
$vnet | Set-AzVirtualNetwork | Out-Null

# 5. Delete NAT Gateway
Remove-AzNatGateway -ResourceGroupName "WorkersRG" -Name "MyNet-natgw" -Force

# 6. Delete NAT Gateway Public IP
Remove-AzPublicIpAddress -ResourceGroupName "WorkersRG" -Name "MyNet-natgw-pip" -Force

# 7. Delete VNet (if no longer needed)
Remove-AzVirtualNetwork -ResourceGroupName "WorkersRG" -Name "MyNet" -Force
```

**SSH Access Without Public IPs:**

Option 1: Jumpbox VM
```powershell
# Create jumpbox with public IP in same VNet
pwsh ./create-spot-vms.ps1 -VMName "jumpbox" -VMSize "Standard_B1s" `
    -ResourceGroupName "WorkersRG" -Location "eastus"
```
```bash
# SSH to jumpbox, then to workers
ssh azureuser@<jumpbox-public-ip>
ssh azureuser@10.0.0.5  # worker1 private IP
```

Option 2: Azure Bastion (managed service, ~$140/month)

Option 3: VPN Gateway (for on-premises connectivity)

**Limitations:**
- NAT Gateway is region-specific; multi-region deployments need multiple NAT Gateways
- No inbound connectivity - VMs cannot be reached from internet directly
- Data processing charges: $0.045/GB for outbound traffic through NAT Gateway
- 5 regions x $37/month = $185/month (may exceed individual IP costs for few VMs per region)

### Security Type Conflicts (PropertyChangeNotAllowed)

When VM creation fails partway through, Azure may leave orphaned OS disks that retain their security type setting (TrustedLaunch or Standard). If a subsequent VM creation attempts to use the same disk name with a different security type, you'll see:

```
PropertyChangeNotAllowed: Changing property 'securityProfile.securityType' is not allowed.
```

**Common Scenarios:**
- ARM VMs (D*p*_v5, D*p*_v6) require Standard security type, but a previous x64 VM attempt created a disk with TrustedLaunch
- Switching between x64 and ARM VM sizes in the same resource group
- Retry after TrustedLaunch failure leaves orphaned disk

**Automatic Handling (create-spot-vms.ps1):**

The script handles this automatically in three ways:
1. **Pre-creation cleanup**: Checks for and deletes orphaned OS disks before VM creation
2. **Error detection + retry**: Detects the specific error, cleans up the disk, and retries
3. **TrustedLaunch fallback**: When TrustedLaunch fails, cleans disk and retries with Standard

**Manual Cleanup:**
```powershell
# List orphaned OS disks
Get-AzDisk -ResourceGroupName "MyRG" | Where-Object { $_.ManagedBy -eq $null }

# Delete specific orphaned disk
Remove-AzDisk -ResourceGroupName "MyRG" -DiskName "myvm-osdisk" -Force

# Delete entire resource group (cleanest approach for spot VMs)
Remove-AzResourceGroup -Name "MyRG" -Force
```

**Security Type Rules:**
- **ARM VMs** (D*p*_v5, D*p*_v6): Always use Standard (TrustedLaunch not supported)
- **x64 VMs**: Default to TrustedLaunch, auto-fallback to Standard if unsupported
- **-TrustedLaunchOnly switch**: Fail instead of falling back (for strict security requirements)

### Azure Preview Features (Feature Flags)

Some newer VM series (like AMD v7 Turin) require Azure feature flag registration before use. If you see errors like "not available to the current subscription" with "feature flags registered", the VM size is in preview.

**Enable Preview Features via Azure Portal:**

1. Sign in to [Azure Portal](https://portal.azure.com)
2. Search for **"Preview features"** in the top search box
3. Or navigate: **Subscriptions** -> Select your subscription -> **Settings** -> **Preview features**
4. Find the feature (e.g., search for "DALV7" for v7 series)
5. Click **Register**

**Registration Status:**
- **Not registered** - Feature available but not enabled
- **Pending** - Registration submitted, awaiting Microsoft approval
- **Registered** - Feature is active and usable

**Enable via Azure CLI:**
```bash
# Register a feature flag
az feature register --namespace Microsoft.Compute --name DALV7Series

# Check registration status
az feature show --namespace Microsoft.Compute --name DALV7Series

# After approval, propagate to provider
az provider register -n Microsoft.Compute
```

**Important Notes:**
- Some features require Microsoft approval and cannot be self-registered
- Features that don't support self-registration may not appear in the portal
- For restricted previews, contact Microsoft support or wait for general availability
- Use `preview-vm-exclusions.txt` with `--exclude-sku-patterns-file` to avoid preview VM sizes

**Workaround - Exclude Preview VMs:**
```bash
# Exclude v7 series (and other preview SKUs) from price queries (~130 pages all regions)
python vm-spot-price.py --min-cores 4 --max-cores 64 --exclude-sku-patterns-file preview-vm-exclusions.txt

# Faster with region filter (~4 pages)
python vm-spot-price.py --cpu 64 --no-burstable --region eastus --exclude-sku-patterns-file preview-vm-exclusions.txt
```

See [Microsoft Learn - Set up preview features](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/preview-features) for more details.

### Preview Feature Management Scripts

Two scripts are available for managing Azure preview features:

**1. register-preview-features.ps1** (Azure PowerShell, full-featured)
```powershell
# List all preview features
pwsh register-preview-features.ps1 -ListOnly

# Register all unregistered Microsoft.Compute features
pwsh register-preview-features.ps1 -ProviderNamespace "Microsoft.Compute" -Force

# Check status of specific feature
pwsh register-preview-features.ps1 -ProviderNamespace "Microsoft.Compute" -FeatureName "AutomaticZoneRebalancing" -CheckStatus

# Unregister a problematic feature
pwsh register-preview-features.ps1 -ProviderNamespace "Microsoft.Compute" -FeatureName "AutomaticZoneRebalancing" -Unregister

# Export to CSV for documentation
pwsh register-preview-features.ps1 -ProviderNamespace "Microsoft.Compute" -ListOnly -ExportPath "features.csv"
```

**2. manage-compute-features.ps1** (Azure CLI, simpler, with backup/restore)

Location: `C:\q\linux-fishtest-scripts\manage-compute-features.ps1`

```powershell
# List all Microsoft.Compute features with summary
pwsh C:\q\linux-fishtest-scripts\manage-compute-features.ps1 -Action List

# Save current state to JSON (for backup before changes)
pwsh C:\q\linux-fishtest-scripts\manage-compute-features.ps1 -Action Save
# Creates: compute-features-20260111-143022.json

# Save to specific file
pwsh C:\q\linux-fishtest-scripts\manage-compute-features.ps1 -Action Save -OutputFile "my-backup.json"

# Enable all features except problematic ones (default excludes AutomaticZoneRebalancing)
pwsh C:\q\linux-fishtest-scripts\manage-compute-features.ps1 -Action EnableAll

# Enable all except multiple features
pwsh C:\q\linux-fishtest-scripts\manage-compute-features.ps1 -Action EnableAll -ExcludeFeatures @("AutomaticZoneRebalancing", "SomeOther")

# Restore features to saved state (register/unregister as needed)
pwsh C:\q\linux-fishtest-scripts\manage-compute-features.ps1 -Action Restore -InputFile "my-backup.json"
```

**Workflow for Safe Feature Testing:**
```powershell
# 1. Save current state before experimenting
pwsh manage-compute-features.ps1 -Action Save -OutputFile "before-testing.json"

# 2. Enable preview features you want to test
az feature register --namespace Microsoft.Compute --name SomeNewFeature

# 3. Test your workloads...

# 4. If issues occur, restore to known-good state
pwsh manage-compute-features.ps1 -Action Restore -InputFile "before-testing.json"
```

**Key Differences:**
| Feature | register-preview-features.ps1 | manage-compute-features.ps1 |
|---------|------------------------------|----------------------------|
| Backend | Azure PowerShell (Az module) | Azure CLI (az) |
| Namespaces | All providers | Microsoft.Compute only |
| State backup | CSV export | JSON backup/restore |
| Bulk enable | Yes | Yes (with exclusions) |
| Restore | No | Yes (diff-based restore) |

## Security

This repository uses Trivy and CodeQL security scanning. See [SECURITY.md](SECURITY.md) for details.

## License 

Copyright 2023-2026 by Maxim Masiutin. All rights reserved.

Individual script licenses may vary - check script headers for specific licensing information.