<#
.SYNOPSIS
    Imports and publishes runbooks into an Azure Automation Account.

.DESCRIPTION
    Finds all .ps1 runbook files in the runbooks\ directory (excluding the
    common\ subdirectory), imports each one into the specified Azure Automation
    Account, and publishes them. Also imports the EsuHelpers.psm1 module from
    runbooks\common\ as an Automation Account module by uploading the zipped
    module to Azure Blob Storage, generating a SAS URI, and passing it to
    New-AzAutomationModule.

.PARAMETER ResourceGroupName
    The name of the Azure resource group containing the Automation Account.

.PARAMETER AutomationAccountName
    The name of the Azure Automation Account to import runbooks into.

.PARAMETER StorageAccountName
    The name of the Azure Storage Account used to stage module zip files.

.PARAMETER StorageContainerName
    The name of the blob container used to stage module zip files.
    Defaults to 'automation-modules'.

.EXAMPLE
    .\Import-Runbooks.ps1 -ResourceGroupName "rg-esu-dev" -AutomationAccountName "aa-esu-dev" `
        -StorageAccountName "stesustaging"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$AutomationAccountName,

    [Parameter(Mandatory = $true)]
    [string]$StorageAccountName,

    [Parameter(Mandatory = $false)]
    [string]$StorageContainerName = 'automation-modules'
)

$ErrorActionPreference = 'Stop'

# Resolve repository root relative to this script
$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$runbooksDir = Join-Path $repoRoot 'runbooks'
$commonDir = Join-Path $runbooksDir 'common'

try {
    # Find all .ps1 runbook files, excluding the common\ subdirectory
    $runbookFiles = Get-ChildItem -Path $runbooksDir -Filter '*.ps1' -Recurse |
        Where-Object { $_.FullName -notlike "$commonDir\*" }

    $importedCount = 0

    if ($runbookFiles.Count -eq 0) {
        Write-Warning "No .ps1 runbook files found in '$runbooksDir' (excluding common\)."
    }
    else {
        foreach ($file in $runbookFiles) {
            $runbookName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
            Write-Host "Importing runbook '$runbookName' from '$($file.FullName)'..." -ForegroundColor Cyan

            Import-AzAutomationRunbook `
                -ResourceGroupName $ResourceGroupName `
                -AutomationAccountName $AutomationAccountName `
                -Path $file.FullName `
                -Name $runbookName `
                -Type PowerShell `
                -Force

            Write-Host "Publishing runbook '$runbookName'..." -ForegroundColor Cyan
            Publish-AzAutomationRunbook `
                -ResourceGroupName $ResourceGroupName `
                -AutomationAccountName $AutomationAccountName `
                -Name $runbookName

            $importedCount++
            Write-Host "Runbook '$runbookName' imported and published." -ForegroundColor Green
        }
    }

    # Import the EsuHelpers module via Azure Blob Storage
    $modulePath = Join-Path $commonDir 'EsuHelpers.psm1'
    if (Test-Path $modulePath) {
        $moduleName = 'EsuHelpers'
        $blobName = "$moduleName.zip"
        $tempDir = $null

        Write-Host "Importing module '$moduleName' from '$modulePath'..." -ForegroundColor Cyan

        try {
            # Package the module into a zip
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "EsuHelpers_$([guid]::NewGuid().ToString('N'))"
            $moduleDir = New-Item -Path (Join-Path $tempDir $moduleName) -ItemType Directory -Force
            Copy-Item -Path $modulePath -Destination $moduleDir.FullName
            $zipPath = Join-Path $tempDir "$moduleName.zip"
            Compress-Archive -Path "$($moduleDir.FullName)\*" -DestinationPath $zipPath -Force
            Write-Host "Module packaged to '$zipPath'." -ForegroundColor Cyan

            # Get storage context
            $storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
            $storageContext = $storageAccount.Context

            # Ensure the container exists
            $container = Get-AzStorageContainer -Name $StorageContainerName -Context $storageContext -ErrorAction SilentlyContinue
            if (-not $container) {
                Write-Host "Creating storage container '$StorageContainerName'..." -ForegroundColor Cyan
                New-AzStorageContainer -Name $StorageContainerName -Context $storageContext -Permission Off | Out-Null
            }

            # Upload the zip to blob storage
            Write-Host "Uploading module zip to blob storage..." -ForegroundColor Cyan
            Set-AzStorageBlobContent `
                -Container $StorageContainerName `
                -File $zipPath `
                -Blob $blobName `
                -Context $storageContext `
                -Force | Out-Null

            # Generate a SAS URI with 1-hour expiry
            $sasToken = New-AzStorageBlobSASToken `
                -Container $StorageContainerName `
                -Blob $blobName `
                -Context $storageContext `
                -Permission 'r' `
                -ExpiryTime (Get-Date).AddHours(1)

            $blobUri = "$($storageContext.BlobEndPoint)$StorageContainerName/$blobName$sasToken"
            Write-Host "Generated SAS URI for module blob (expires in 1 hour)." -ForegroundColor Cyan

            # Import the module into the Automation Account
            New-AzAutomationModule `
                -ResourceGroupName $ResourceGroupName `
                -AutomationAccountName $AutomationAccountName `
                -Name $moduleName `
                -ContentLinkUri $blobUri

            Write-Host "Module '$moduleName' imported." -ForegroundColor Green
        }
        finally {
            # Clean up the staging blob
            if ($storageContext) {
                Write-Host "Cleaning up staging blob..." -ForegroundColor Cyan
                Remove-AzStorageBlob -Container $StorageContainerName -Blob $blobName -Context $storageContext -Force -ErrorAction SilentlyContinue
            }

            # Clean up local temp files
            if ($tempDir -and (Test-Path $tempDir)) {
                Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    else {
        Write-Warning "Module file not found: $modulePath"
    }

    # Output summary
    Write-Host "`n--- Import Summary ---" -ForegroundColor Cyan
    Write-Host "Runbooks imported and published: $importedCount" -ForegroundColor Green
    if (Test-Path $modulePath) {
        Write-Host "Module imported: EsuHelpers" -ForegroundColor Green
    }
}
catch {
    Write-Error "Import error: $_"
    exit 1
}
