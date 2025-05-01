# Useful Scripts for Microsoft Azure
1. **change-ip-to-static.ps1**: This script changes all public IP addresses from dynamic to static. Therefore, if you turn off a virtual machine to stop payment for units of time, Azure will not take your IP address but will keep it. When you turn it on, it will boot with the same IP.
1. **monitor-eviction.py**: Monitors a spot VM to determine whether it is being evicted and stops a Linux service before the VM instance is stopped.
1. **vm-spot-price.py**: Returns a sorted list (by VM instance spot price) of Azure regions to find cheapest spot instance price. Examples of use:  
  `python vm-spot-price.py --cpu 4 --sku-pattern "B#s_v2"`  
  `python vm-spot-price.py --cpu 4 --sku-pattern "B#ls_v2" --series-pattern "Bsv2"`  
  `python vm-spot-price.py --sku-pattern "B4ls_v2" --series-pattern "Bsv2" --return-region`  
1. **blob-storage-price.py**: Returns Azure regions sorted by average blob storage price (page/block, premium/general, etc.) to find cheapest cloud storage price. Examples of use:  
  `python blob-storage-price.py`  
  `python blob-storage-price.py --blob-types "General Block Blob v2"`  
  `python blob-storage-price.py --blob-types "General Block Blob v2, Premium Block Blob"`  

1. **create-spot-vms.ps1**: Creates a series of Azure VM spot instances automatically.
1. **set-storage-account-content-headers.ps1**: Sets Azure static website files content headers (such as Content-Type or Cache-Control).
