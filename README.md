# Introduction - Useful Scripts for Microsoft Azure

1. **change-ip-to-static.ps1**: This script changes all public IP addresses from dynamic to static. Therefore, if you turn off a virtual machine to stop payment for units of time, Azure will not take your IP address but will keep it. When you turn it on, it will boot with the same IP.
1. **monitor-eviction.py**: Monitors a spot VM to determine whether it is being evicted and stops a Linux service before the VM instance is stopped.
1. **vm-spot-price.py**: Returns a sorted list (by VM instance spot price) of Azure regions to find cheapest spot instance price. Supports multi-VM comparison and per-core pricing analysis. Examples of use:
  `python vm-spot-price.py --cpu 4 --sku-pattern "B#s_v2"`
  `python vm-spot-price.py --vm-sizes "D4pls_v5,D4ps_v5,F4s_v2,D4as_v5" --return-region`
  `python vm-spot-price.py --min-cores 2 --max-cores 64 --general-compute --return-region`  
1. **blob-storage-price.py**: Returns Azure regions sorted by average blob storage price (page/block, premium/general, etc.) to find cheapest cloud storage price. Examples of use:  
  `python blob-storage-price.py`  
  `python blob-storage-price.py --blob-types "General Block Blob v2"`  
  `python blob-storage-price.py --blob-types "General Block Blob v2, Premium Block Blob"`  

1. **create-spot-vms.ps1**: Creates Azure Spot VMs with full ARM64 support. Auto-detects latest Ubuntu minimal image based on CPU architecture (ARM64 Cobalt/Ampere or x64 AMD/Intel).
1. **set-storage-account-content-headers.ps1**: Sets Azure static website files content headers (such as Content-Type or Cache-Control).
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
   - Exclusion Filters: Exclude specific regions, VM sizes, or ARM VMs via `--exclude-arm`
   - Advanced Options: Series pattern matching, non-spot instance filtering, single region output
   - **Quality Filtering**: Automatically filters out invalid or zero-price (free tier) instances to ensure valid spot pricing.
   - PowerShell Integration: `--return-region` outputs "region vmsize price unit" format; `--return-region-json` outputs JSON for direct parsing
   - Use Cases: Cost optimization before VM deployment, automated region selection
   - Examples:
     ```bash
     # Single SKU pattern
     python vm-spot-price.py --cpu 4 --sku-pattern "B#s_v2"
     python vm-spot-price.py --sku-pattern "B4ls_v2" --series-pattern "Bsv2" --return-region

     # Multi-VM comparison (find cheapest across multiple sizes)
     python vm-spot-price.py --vm-sizes "D4pls_v5,D4ps_v5,F4s_v2,D4as_v5" --return-region

     # Per-core pricing (find cheapest $/core across all D and F series)
     python vm-spot-price.py --min-cores 2 --max-cores 64 --general-compute
     python vm-spot-price.py --min-cores 4 --max-cores 32 --latest --return-region
     python vm-spot-price.py --min-cores 2 --max-cores 16 --series "Dasv6,Fasv7"

     # Per-core filtering options
     # --general-compute: Only D-series (general purpose) and F-series (compute optimized)
     # --latest: Only latest generation (v6/v7) - AMD Genoa/Turin, ARM Cobalt
     # --no-burstable: Exclude B-series burstable VMs
     # --burstable-only: Only B-series burstable VMs
     # --series: Comma-separated list of specific VM series

     # ARM-based VMs (Ampere Altra processors) - automatic detection
     python vm-spot-price.py --vm-sizes "D4pls_v5,D4ps_v5" --return-region  # ARM VMs work natively
     python vm-spot-price.py --min-cores 4 --max-cores 16 --exclude-arm  # Exclude ARM VMs from results

     # Exclude specific regions or VM sizes
     python vm-spot-price.py --vm-sizes "D4pls_v5,D4ps_v5" --exclude-regions "centralindia,eastasia"
     python vm-spot-price.py --vm-sizes "D4pls_v5,D4ps_v5" --exclude-regions-file regions1.txt

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

5. **change-ip-to-static.ps1**: Prevent IP address loss during VM shutdowns
   - Purpose: Converts dynamic public IPs to static to retain addresses when VMs are deallocated
   - Cost Benefit: Allows stopping VMs for cost savings without losing IP assignments
   - Automation: Bulk conversion of all public IPs in subscription

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

7. **set-storage-account-content-headers.ps1**: Static website optimization
   - Purpose: Configure proper Content-Type and Cache-Control headers for Azure static websites
   - Performance: Improves website loading times and SEO through proper HTTP headers

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

**Find cheapest region for a specific VM:**
```bash
python vm-spot-price.py --sku-pattern "B4ls_v2" --return-region
```

**Find cheapest spot option across multiple VM sizes:**
```bash
python vm-spot-price.py --vm-sizes "D4pls_v5,D4ps_v5,F4s_v2,D4as_v5,D4s_v5" --return-region
# Output: centralindia Standard_D4as_v5
```

**Find cheapest spot price per core (2-64 vCPUs, D and F series):**
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

**Convert dynamic IPs to static (PowerShell 7.5+):**
```powershell
pwsh ./change-ip-to-static.ps1 -Force
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

For deployments with many VMs, using NAT Gateway instead of individual Public IPs can significantly reduce costs:

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
    +-- VM1 (no public IP)
    +-- VM2 (no public IP)
    +-- ...
    +-- VM20 (no public IP)
    |
[Jumpbox VM] <-- 1 Public IP for SSH access
```

**Cost Comparison (20+ VMs):**
| Approach | Monthly Cost |
|----------|-------------|
| 21 Standard Public IPs | ~$77/month |
| 1 NAT Gateway + 1 Jumpbox IP | ~$37/month + data costs |

**Implementation:**
```powershell
# Create VMs with NAT Gateway (no individual public IPs)
pwsh ./create-spot-vms.ps1 -NoPublicIP -UseNatGateway -VMName "worker1"

# Create one Jumpbox VM with public IP for SSH access
pwsh ./create-spot-vms.ps1 -VMName "jumpbox" -VMSize "Standard_B1s"
```

**SSH Access Pattern:**
```bash
# SSH to jumpbox first
ssh azureuser@<jumpbox-public-ip>

# From jumpbox, SSH to workers via private IPs
ssh azureuser@10.0.0.5  # worker1 private IP
ssh azureuser@10.0.0.6  # worker2 private IP
```

**Limitations:**
- NAT Gateway is region-specific; multi-region deployments need multiple NAT Gateways
- 5 regions x $33/month = $165/month (may exceed individual IP costs)
- Jumpbox becomes single point of entry (consider availability)

## Security

This repository uses Trivy and CodeQL security scanning. See [SECURITY.md](SECURITY.md) for details.

## License 

Copyright 2023-2025 by Maxim Masiutin. All rights reserved.

Individual script licenses may vary - check script headers for specific licensing information.