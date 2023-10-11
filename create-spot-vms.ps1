# create-spot-vms.ps1
# Creates a series of Azure VM spot instances automatically
# Copyright 2023 by Maxim Masiutin. All rights reserved.


# Configuration

$vmNumberFrom = 1
# Creates 16 virtual machines called from vm1 to vm16
$vmNumberTo = 16
# The virtual machines will be created in the resource group specified in the $ResourceGroupName variable below; if the resource group does not exist, it will be created
$ResourceGroupName = 'MyResourceGroup'
$LocationName = 'eastus'
$vmSize = 'Standard_D4as_v5'
$diskStorageAccountType = 'Standard_LRS'
$diskImageOffer = '0001-com-ubuntu-minimal-jammy'
$diskImageSku = 'minimal-22_04-lts-gen2'
$diskImagePublisher = 'Canonical'
$diskImageVersion = 'latest'
$securityType = 'TrustedLaunch'
$NetworkName = 'MyNet'
$SubnetName = 'MySubnet'
$SubnetAddressPrefix = '10.0.0.0/24'
$VnetAddressPrefix = '10.0.0.0/16'

# Use the following vault specified in $VaultName below from the resource group specified in $KeyVaultResourceGroupName below to get the secrets for the VMs; this resource group must exist, it will not be created automatically by this script
$KeyVaultResourceGroupName = 'MyKeyVaultResourceGroup'
$VaultName = 'MyVault'
# Take the username for the VM from the Key Vault secret
$SecretName = 'vmOsAdminUserName'
$VMLocalAdminUsername = (Get-AzKeyVaultSecret -VaultName $VaultName -ResourceGroupName $KeyVaultResourceGroupName -Name $SecretName).SecretValueText
# Take the password for the VM from the Key Vault secret
$SecretName = 'vmOsAdminPassword'
$VMLocalAdminPassword = (Get-AzKeyVaultSecret -VaultName $VaultName -ResourceGroupName $KeyVaultResourceGroupName -Name $SecretName).SecretValueText
# Take the script to be run on the VM at start for the URL stored in the the Key Vault secret
$SecretName = 'vmScriptUrl'
$VMLocalScriptUrl = (Get-AzKeyVaultSecret -VaultName $VaultName -ResourceGroupName $KeyVaultResourceGroupName -Name $SecretName).SecretValueText
# It will download the script from the specified URL, save it to 1.bash, make it executable, run it saving the stdout to and stderr to 1-log.txt and 2-log txt, respectively, then delete the script and and reboot the VM
$VMLocalScriptLine = "cd /tmp/;wget $VMLocalScriptUrl;chmod +x 1.bash;sudo ./1.bash 1>1-log.txt 2>2-log.txt;rm ./1.bash;sudo reboot"


# Actions

# Displays a progress bar with the specified activity and status messages.
$Activity = "Provisioning RG $ResourceGroupName at $LocationName"
$Status = "Checking existance of RG"
Write-Progress -Activity $Activity -Status $Status

# Creates a new Azure Resource Group if it doesn't exist, or retrieves an existing one.
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

# Create a new virtual network or uses an existing one, and configures a single subnet for the virtual machines; if this subnet already exists, it will be used as is without any changes
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

# Retrive a subnet ID for the virtual machines that we will create and store it in the $subnetId variable for later use
$subnetId = $Vnet.Subnets[0].Id

# Create a credential object for the virtual machines that we will create and store it in the $Credential variable for later use
$VMLocalAdminSecurePassword = ConvertTo-SecureString $VMLocalAdminPassword -AsPlainText -Force
$Credential = New-Object System.Management.Automation.PSCredential ($VMLocalAdminUsername, $VMLocalAdminSecurePassword);

# Main loop to create the virtual machines
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
  $vmConfig = Set-AzVMSourceImage -VM $vmConfig -PublisherName $diskImagePublisher -Offer $diskImageOffer -Skus $diskImageSku -Version $diskImageVersion
  $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $NIC.Id -DeleteOption "Delete"
  $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Linux -ComputerName $vmName -Credential $Credential
  $vmConfig = Set-AzVMOSDisk -VM $vmConfig -Name "OsDisk$_" -DeleteOption "Delete" -Linux -StorageAccountType $diskStorageAccountType -CreateOption "FromImage"

  $Status = "Creating new VM from config"
  Write-Progress -Activity $Activity -Status $Status

  New-AzVm -ResourceGroupName $ResourceGroupName -VM $vmConfig -Location $LocationName -Verbose

  $Status = "Running command on VM"
  Write-Progress -Activity $Activity -Status $Status

  Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmName -CommandId 'RunShellScript' -ScriptString $VMLocalScriptLine -AsJob
}

