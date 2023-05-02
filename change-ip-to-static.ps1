# change-ip-to-static.ps1
# Change all public IP addresses from Dynamic to Static. Therefore, if you turn off a virtual machine to stop payment for units of time, Azure would not take your IP address but will keep it. And when you turn it on, it will boot with the same IP.
# Copyright 2022 by Maxim Masiutin. All rights reserved.

$IPs = Get-AzPublicIpAddress;
$Static = "Static";
foreach ($PublicIP in $IPs) {
    $Method = $PublicIP.PublicIpAllocationMethod;
    $Name = $PublicIP.Name;
    if ($Method -eq $Static) {
        Write-Host "The method of $Name is already $Static.";
    }
    else {
        $Activity = "Changing the method of $Name from $Method to $Static ...";
        Write-Progress -Activity $Activity -Status "Assigning the method of $Name to $Static...";
        $PublicIP.PublicIpAllocationMethod = $Static;
        Write-Progress -Activity $Activity -Status "Setting the method of $Name using Set-AzPublicIpAddress...";
        Set-AzPublicIpAddress -PublicIpAddress $PublicIP | Out-null;
        Write-Progress -Activity $Activity -Status "Querying the method of $Name using Get-AzPublicIpAddress";
        $ModifiedAddress = Get-AzPublicIpAddress -Name $Name -ResourceGroupName $PublicIP.ResourceGroupName
        $NewMethod = $ModifiedAddress.PublicIpAllocationMethod;
        if ($NewMethod -eq $Static) {
            Write-Host "The method for $Name has successfully changed from $Method to $Static.";
        }
        else {
            Write-Error -Message "Cannot change the method for $Name to $Static, it is still $NewMethod!";
        }
    }
}
