# Useful scripts for Microsoft Azure
1. (change-ip-to-static.ps1) This script changes all public IP addresses from Dynamic to Static; therefore, if you turn off a virtual machine to stop payment for units of time, Azure would not take your IP address but will keep it; and when you turn it on, it will boot with the same IP.
1. (monitor-eviction.py) Monitors a spot VM whether it is being evicted and stops a Linux service before the VM is being stopped.
1. (vm-spot-price.py) Returns sorted (by VM spot price) list of Azure regions.
1. (create-spot-vms.ps1) Creates a series of Azure VM spot instances automatically.