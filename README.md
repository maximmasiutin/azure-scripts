# Introduction - Useful Scripts for Microsoft Azure

1. **change-ip-to-static.ps1**: This script changes all public IP addresses from dynamic to static. Therefore, if you turn off a virtual machine to stop payment for units of time, Azure will not take your IP address but will keep it. When you turn it on, it will boot with the same IP.
1. **monitor-eviction.py**: Monitors a spot VM to determine whether it is being evicted and stops a Linux service before the VM instance is stopped.
1. **vm-spot-price.py**: Returns a sorted list (by VM instance spot price) of Azure regions to find cheapest spot instance price. Supports multi-VM comparison to find the cheapest option across different VM sizes. Examples of use:
  `python vm-spot-price.py --cpu 4 --sku-pattern "B#s_v2"`
  `python vm-spot-price.py --cpu 4 --sku-pattern "B#ls_v2" --series-pattern "Bsv2"`
  `python vm-spot-price.py --sku-pattern "B4ls_v2" --series-pattern "Bsv2" --return-region`
  `python vm-spot-price.py --vm-sizes "D4pls_v5,D4ps_v5,F4s_v2,D4as_v5" --return-region`  
1. **blob-storage-price.py**: Returns Azure regions sorted by average blob storage price (page/block, premium/general, etc.) to find cheapest cloud storage price. Examples of use:  
  `python blob-storage-price.py`  
  `python blob-storage-price.py --blob-types "General Block Blob v2"`  
  `python blob-storage-price.py --blob-types "General Block Blob v2, Premium Block Blob"`  

1. **create-spot-vms.ps1**: Creates a series of Azure VM spot instances automatically.
1. **set-storage-account-content-headers.ps1**: Sets Azure static website files content headers (such as Content-Type or Cache-Control).
1. **monitor-stddev.py**: Monitors an URL by doing requests at specific intervals and publishes results to a static Azure website or to local files, and can use Azure CosmosDB as an intermediate data storage, see [monitor-stddev.md](monitor-stddev.md) for details.
1. **azure-swap.py**: A tool that looks for local temporary disk and creates a swap file of 90% of that storage, leaving 10% available. It creates an autostart server in case of Azure removed the disk if machin was stopped.  


# Details 
A collection of Python and PowerShell utilities for Azure cost optimization, monitoring, and automation.
## Core Utilities
### Cost Optimization Scripts

1. **vm-spot-price.py**: Find the cheapest Azure regions for spot VM instances
   - Key Features: Multi-region price comparison, custom CPU/SKU filtering, spot vs regular pricing
   - Multi-VM Comparison: Compare multiple VM sizes at once with `--vm-sizes` parameter
   - Exclusion Filters: Exclude specific regions or VM sizes via command line or file
   - Advanced Options: Series pattern matching, non-spot instance filtering, single region output
   - PowerShell Integration: `--return-region` outputs "region vmsize" format for easy parsing
   - Use Cases: Cost optimization before VM deployment, automated region selection
   - Examples:
     ```bash
     # Single SKU pattern
     python vm-spot-price.py --cpu 4 --sku-pattern "B#s_v2"
     python vm-spot-price.py --sku-pattern "B4ls_v2" --series-pattern "Bsv2" --return-region

     # Multi-VM comparison (find cheapest across multiple sizes)
     python vm-spot-price.py --vm-sizes "D4pls_v5,D4ps_v5,F4s_v2,D4as_v5" --return-region

     # Exclude specific regions or VM sizes
     python vm-spot-price.py --vm-sizes "D4pls_v5,D4ps_v5" --exclude-regions "centralindia,eastasia"
     python vm-spot-price.py --vm-sizes "D4pls_v5,D4ps_v5" --exclude-regions-file regions1.txt --exclude-regions-file regions2.txt

     # PowerShell integration
     # $result = python vm-spot-price.py --vm-sizes "D4pls_v5,F4s_v2" --return-region
     # $region, $vmSize = $result -split ' '
     # New-AzVM -Location $region -Size $vmSize -Priority Spot ...
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

6. **create-spot-vms.ps1**: Automated spot VM deployment
   - Features: Batch creation of multiple spot instances with consistent configuration
   - Cost Optimization: Leverages spot pricing for development/testing environments
   - **Automatic Quota Request**: Use `-RequestQuota` switch to automatically create an Azure Support ticket if spot quota is insufficient in the target region.
   - **Custom Initialization**: Supports passing cloud-init scripts via `-CustomData` or downloading from `-InitScriptUrl`.

7. **set-storage-account-content-headers.ps1**: Static website optimization
   - Purpose: Configure proper Content-Type and Cache-Control headers for Azure static websites
   - Performance: Improves website loading times and SEO through proper HTTP headers

8. **azure_swap_fixed.bash**: Dynamic SWAP provisioning for Azure VMs with temporary storage
   - Key Features: Automatically detects Azure "Temporary Storage" partitions, uses 90% for swap files
   - Resilience: Handles ephemeral storage by recreating swap on each boot via systemd service
   - Fallback: Creates 2GB+ swap in /mnt if no temporary storage found
   - Security: Comprehensive input validation, privilege checks, and secure file operations
   - Benefits: Optimizes memory usage on VMs with local SSDs that reset on stop/start
   - Usage:
     ```bash
     sudo ./azure_swap_fixed.bash
     sudo systemctl status robust-swap-setup.service
     ```

## Prerequisites

**Python Requirements:**
- Python 3.6+
- Required packages: `curl_cffi`, `tabulate`, `azure-storage-blob`, `azure-data-tables`, `Pillow`

**PowerShell Requirements:**
- Azure PowerShell module
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
sudo ./azure_swap_fixed.bash
# Verify service is running
sudo systemctl status robust-swap-setup.service
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

## Security

This repository uses Trivy and CodeQL security scanning. See [SECURITY.md](SECURITY.md) for details.

## License

Copyright 2023-2025 by Maxim Masiutin. All rights reserved.

Individual script licenses may vary - check script headers for specific licensing information.

