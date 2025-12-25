# set-storage-account-content-headers.ps1
# Sets Azure static website files content headers (such as Content-Type or Cache-Control)
# Copyright 2023-2025 by Maxim Masiutin. All rights reserved.
#
# Requires: PowerShell 7.5 or later (run with pwsh)

# PSScriptAnalyzer suppressions for interactive console script
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification='Interactive console script requires colored output')]
param(
    [Parameter(Mandatory = $false, ParameterSetName = 'Key')]
    [string]$StorageAccountName,

    [Parameter(Mandatory = $false, ParameterSetName = 'Key')]
    [string]$StorageAccountKey,

    [Parameter(Mandatory = $false, ParameterSetName = 'SAS')]
    [string]$SASToken,

    [Parameter(Mandatory = $false, ParameterSetName = 'BlobSasUrl')]
    [string]$BlobSasUrl,

    [Parameter(Mandatory = $false)]
    [string]$FileName,

    [Parameter(Mandatory = $false)]
    [string]$CacheControl,

    [Parameter(Mandatory = $false)]
    [string]$ContentType,

    [Parameter(Mandatory = $false)]
    [string]$LocalFilePath
)

# PowerShell version check
if ($PSVersionTable.PSVersion.Major -lt 7 -or
    ($PSVersionTable.PSVersion.Major -eq 7 -and $PSVersionTable.PSVersion.Minor -lt 5)) {
    Write-Host "ERROR: This script requires PowerShell 7.5 or later." -ForegroundColor Red
    Write-Host "Current version: $($PSVersionTable.PSVersion)" -ForegroundColor Red
    Write-Host "Please install PowerShell 7.5+ from https://github.com/PowerShell/PowerShell/releases" -ForegroundColor Yellow
    Write-Host "Run this script with: pwsh $($MyInvocation.MyCommand.Path)" -ForegroundColor Yellow
    exit 1
}

if (-not $CacheControl -and -not $ContentType -and -not $LocalFilePath) {
    Write-Error "At least one of CacheControl, ContentType, or LocalFilePath must be specified."
    exit 1
}

if ($LocalFilePath -and -not (Test-Path -Path $LocalFilePath -PathType Leaf)) {
    Write-Error "LocalFilePath '$LocalFilePath' does not exist or is not a file."
    exit 1
}

if (-not $StorageAccountKey -and -not $SASToken -and -not $BlobSasUrl) {
    Write-Error "You must specify either StorageAccountKey, SASToken, or BlobSasUrl."
    exit 1
}

$requiredAzStorageVersion = [Version]'5.0.0'
$installedModule = Get-Module -ListAvailable -Name Az.Storage | Sort-Object Version -Descending | Select-Object -First 1

if (-not $installedModule -or $installedModule.Version -lt $requiredAzStorageVersion) {
    Write-Host "Az.Storage $requiredAzStorageVersion or newer is required. Installing/Updating..."
    Install-Module -Name Az.Storage -Force -Scope CurrentUser -MinimumVersion $requiredAzStorageVersion
}
Import-Module Az.Storage -Force

if ($BlobSasUrl) {
    $storageAccountName = ([regex]::Match($BlobSasUrl, 'https://(.*?)\.blob\.core\.windows\.net').Groups[1].Value)
    if ($BlobSasUrl -notmatch "\?") {
        Write-Error "The BlobSasUrl does not contain a SAS token. Please provide a URL with a SAS token (e.g., ...?sp=rwl&...)."
        exit 1
    }
    $sasToken = ($BlobSasUrl -split '\?',2)[1]
    if (-not $sasToken) {
        Write-Error "No SAS token could be extracted from BlobSasUrl. Please check your URL."
        exit 1
    }

    # Parse SAS token into a hashtable for easy lookup
    $sasParams = @{}
    foreach ($pair in $sasToken -split '&') {
        $kv = $pair -split '=', 2
        if ($kv.Length -eq 2) {
            $sasParams[$kv[0]] = $kv[1]
        }
    }

    # Check for 'sp' parameter and required permissions
    if (-not $sasParams.ContainsKey('sp') -or [string]::IsNullOrEmpty($sasParams['sp'])) {
        Write-Error "The SAS token extracted from BlobSasUrl is missing the 'sp' (signed permissions) parameter or it is empty.`n
Your SAS token: $sasToken`n
Example required: sp=rwl (read, write, list)."
        exit 1
    }

    # Build required permissions list based on operation
    $requiredPermissions = @()
    if ($LocalFilePath) {
        # Upload requires write and create permissions
        $requiredPermissions += 'w'
        $requiredPermissions += 'c'
    } else {
        # Listing blobs requires list permission
        $requiredPermissions += 'l'
    }

    $missingPermissions = $requiredPermissions | Where-Object { $sasParams['sp'] -notlike "*$_*" }
    if ($missingPermissions) {
        $permissionDesc = if ($LocalFilePath) { "upload files" } else { "list blobs" }
        Write-Error "Your SAS token is missing the following required permissions: $($missingPermissions -join ', ')`n
To $permissionDesc, your SAS token must include these permissions. Please regenerate your SAS token with the correct permissions.`n
Current permissions: $($sasParams['sp'])"
        exit 1
    }
    $ctx = New-AzStorageContext -SasToken ('?' + $sasToken) -StorageAccountName $storageAccountName
}

if ($StorageAccountKey) {
    $ctx = New-AzStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $StorageAccountKey
} elseif ($SASToken) {
    $ctx = New-AzStorageContext -StorageAccountName $StorageAccountName -SasToken $SASToken
}

# Upload local file if specified
if ($LocalFilePath) {
    # Determine blob name: use FileName if specified, otherwise use local file name
    if ($FileName) {
        $blobName = $FileName
    } else {
        $blobName = Split-Path -Path $LocalFilePath -Leaf
    }

    Write-Host "Uploading '$LocalFilePath' to blob '$blobName'..."

    # Build upload parameters
    $uploadParams = @{
        File      = $LocalFilePath
        Container = '$web'
        Blob      = $blobName
        Context   = $ctx
        Force     = $true  # Overwrite existing blob
    }

    # Set content type during upload if specified
    if ($ContentType) {
        $uploadParams['Properties'] = @{ ContentType = $ContentType }
    }

    $uploadedBlob = Set-AzStorageBlobContent @uploadParams
    Write-Host "Uploaded blob: $blobName"

    # If headers need to be set after upload
    if ($CacheControl -or $ContentType) {
        $cloudBlob = $uploadedBlob.ICloudBlob
        $cloudBlob.FetchAttributes()
        if ($CacheControl) { $cloudBlob.Properties.CacheControl = $CacheControl }
        if ($ContentType)  { $cloudBlob.Properties.ContentType  = $ContentType  }
        $cloudBlob.SetProperties()
        Write-Host "Updated headers for blob: $blobName"
    }
} else {
    # Original behavior: update headers on existing blobs
    # Get blobs from $web container, optionally filter by FileName or mask
    if ($FileName) {
        $blobs = Get-AzStorageBlob -Container '$web' -Context $ctx | Where-Object { $_.Name -like $FileName }
    } else {
        $blobs = Get-AzStorageBlob -Container '$web' -Context $ctx
    }

    if (-not $blobs) {
        Write-Host "No blobs found matching the specified criteria."
        exit 0
    }

    foreach ($blob in $blobs) {
        $cloudBlob = $blob.ICloudBlob
        $cloudBlob.FetchAttributes() # Ensure all properties are loaded

        if ($CacheControl) { $cloudBlob.Properties.CacheControl = $CacheControl }
        if ($ContentType)  { $cloudBlob.Properties.ContentType  = $ContentType  }

        $cloudBlob.SetProperties()
        Write-Host "Updated headers for blob: $($blob.Name)"
    }
}
