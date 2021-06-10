# Change all public IP addresses from Dynamic to Static. Therefore, if you turn off a virtual machine to stop payment for units of time, Azure would not take your IP address but will keep it. And when you turn it on, it will boot with the same IP.

$IPs = Get-AzPublicIpAddress;
$Static = "Static";
foreach ($PublicIP in $IPs) {
    $Method = $PublicIP.PublicIpAllocationMethod;
    $Name = $PublicIP.Name;
    if ($Method -eq $Static) {
        $message = "The method of " + $Name + " is already " + $Static;
        Write-Progress -Activity $message;
    }
    else {
        Write-Progress -Activity "Changing the method of "+$Name+" from "+$Method+" to "+$Static+"...";
        $PublicIP.PublicIpAllocationMethod = $Static;
        Set-AzPublicIpAddress -PublicIpAddress $PublicIP;
        Write-Progress -Activity "Querying the method of "+$Name+"...";
        $ModifiedAddress = Get-AzPublicIpAddress -Name $Name -ResourceGroupName $PublicIP.ResourceGroupName
        $NewMethod = $ModifiedAddress.PublicIpAllocationMethod;
        if ($NewMethod -eq $Static) {
            Write-Output "The method for "+$Name+" has successfully changed to "+$Static;
        }
        else {
            Write-Error -Message "Cannot change the method for "+$Name+" to "+$Static+", it is still "+$NewMethod+"!!!";
        }
    }
}
