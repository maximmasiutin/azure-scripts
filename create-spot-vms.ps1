# create-spot-vms.ps1 
# Creates a series of Azure VM spot instances automatically 
# Copyright 2023 by Maxim Masiutin. All rights reserved.


# Configuration

$vmNumberFrom = 1
$vmNumberTo = 16 # Creates 16 virtual machines called from vm1 to vm16
$ResourceGroupName = 'MyResourceGroup'
$LocationName = 'eastus'
$vmSize = 'Standard_D4as_v5'
$diskImageOffer = '0001-com-ubuntu-minimal-jammy'
$diskImageSku = 'minimal-22_04-lts-gen2'
$securityType = 'TrustedLaunch'
$NetworkName = 'MyNet'
$SubnetName = 'MySubnet'
$SubnetAddressPrefix = '10.0.0.0/24'
$VnetAddressPrefix = '10.0.0.0/16'
$VMLocalAdminUsername = 'maxim'    # Please modify the username
$VMLocalAdminPassword = '12345678' # Please modify the password
$VMLocalScriptLine = 'cd /tmp/;wget http://example.net/1.bash;chmod +x 1.bash;sudo ./1.bash 1>1-log.txt 2>2-log.txt;rm ./1.bash;sudo reboot' # Example script, please modify

# Actions

$Activity = "Provisioning RG $ResourceGroupName at $LocationName"
$Status = "Checking existance of RG"

Write-Progress -Activity $Activity -Status $Status

$rg = Get-AzResourceGroup -Name $ResourceGroupName -Location $LocationName -ErrorVariable ResourceGroupNotPresent -ErrorAction SilentlyContinue


if ($ResourceGroupNotPresent) {
  $Status = "Creating new RG"
  Write-Progress -Activity $Activity -Status $Status
  $rg = New-AzResourceGroup -Name $ResourceGroupName -Location $LocationName
}
else {
  $Status = "The RG already exists at $rg.Location"
  Write-Progress -Activity $Activity -Status $Status
}

$Activity = "Provisioning virtual network"

$SingleSubnet = New-AzVirtualNetworkSubnetConfig -Name $SubnetName -AddressPrefix $SubnetAddressPrefix
$Vnet = Get-AzVirtualNetwork -Name $NetworkName -ResourceGroupName $ResourceGroupName -ErrorVariable VirtualNetworkNotPresent -ErrorAction SilentlyContinue
if ($VirtualNetworkNotPresent) {
  $Status = "Creating new virtual network"
  Write-Progress -Activity $Activity -Status $Status
  $Vnet = New-AzVirtualNetwork -Name $NetworkName -ResourceGroupName $ResourceGroupName -Location $LocationName -AddressPrefix $VnetAddressPrefix -Subnet $SingleSubnet
}
else {
  $Status = "Using existing virtual network $NetworkName"
  Write-Progress -Activity $Activity -Status $Status
}

$subnetId = $Vnet.Subnets[0].Id

$VMLocalAdminSecurePassword = ConvertTo-SecureString $VMLocalAdminPassword -AsPlainText -Force
$Credential = New-Object System.Management.Automation.PSCredential ($VMLocalAdminUsername, $VMLocalAdminSecurePassword); ; ;

($vmNumberFrom..$vmNumberTo) | foreach-object {
  $vmName = "vm$_"

  $Activity = "Provisioning $vmName $vmSize at $LocationName"

  $Status = "Creating new VM config"
  Write-Progress -Activity $Activity -Status $Status

  $NICName = "NIC$_"
  $NIC = New-AzNetworkInterface -Name $NICName -ResourceGroupName $ResourceGroupName -Location $LocationName -SubnetId $subnetId -EnableAcceleratedNetworking

  $vmConfig = New-AzVMConfig -VMName $vmName -VMSize $vmSize -Priority 'Spot' -EvictionPolicy 'Delete'
  if (-not ([string]::IsNullOrEmpty($securityType))) {
    $vmConfig = Set-AzVMSecurityProfile -VM $vmConfig -SecurityType $securityType
  }
  $vmConfig = Set-AzVMSourceImage -VM $vmConfig -PublisherName 'Canonical' -Offer $diskImageOffer -Skus $diskImageSku -Version 'latest'
  $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $NIC.Id -DeleteOption "Delete"
  $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Linux -ComputerName $vmName -Credential $Credential
  $vmConfig = Set-AzVMOSDisk -VM $vmConfig -Name "OsDisk$_" -DeleteOption "Delete" -Linux -StorageAccountType "Standard_LRS" -CreateOption "FromImage"

  $Status = "Creating new VM from config"
  Write-Progress -Activity $Activity -Status $Status

  New-AzVm -ResourceGroupName $ResourceGroupName -VM $vmConfig -Location $LocationName -Verbose

  $Status = "Running command on VM"
  Write-Progress -Activity $Activity -Status $Status

  Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmName -CommandId 'RunShellScript' -ScriptString $VMLocalScriptLine -AsJob
}

