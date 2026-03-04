<#
.SYNOPSIS
    Deploys the Arc ESU Automation Bicep infrastructure to Azure.

.DESCRIPTION
    Deploys the infrastructure defined in infra\main.bicep to a specified
    Azure resource group using the Azure CLI. Supports dev and prod environments
    with corresponding parameter files, and a WhatIf mode for previewing changes.

.PARAMETER ResourceGroupName
    The name of the Azure resource group to deploy into.

.PARAMETER Location
    The Azure region for the resource group. Defaults to 'eastus'.

.PARAMETER Environment
    The target environment. Must be 'dev' or 'prod'. Defaults to 'dev'.

.PARAMETER WhatIf
    If specified, runs the deployment in what-if mode to preview changes
    without actually deploying.

.EXAMPLE
    .\Deploy-Infrastructure.ps1 -ResourceGroupName "rg-esu-dev" -Environment dev

.EXAMPLE
    .\Deploy-Infrastructure.ps1 -ResourceGroupName "rg-esu-prod" -Location westus2 -Environment prod -WhatIf
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter()]
    [string]$Location = 'eastus',

    [Parameter()]
    [ValidateSet('dev', 'prod')]
    [string]$Environment = 'dev',

    [Parameter()]
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

# Resolve repository root relative to this script
$repoRoot = Split-Path -Path $PSScriptRoot -Parent

try {
    # Validate that az CLI is available
    if (-not (Get-Command 'az' -ErrorAction SilentlyContinue)) {
        throw "Azure CLI ('az') is not installed or not found in PATH. Please install it from https://aka.ms/installazurecli"
    }
    Write-Host "Azure CLI found." -ForegroundColor Green

    # Determine the parameter file path
    $parameterFile = Join-Path $repoRoot "infra\parameters\$Environment.bicepparam"
    if (-not (Test-Path $parameterFile)) {
        throw "Parameter file not found: $parameterFile"
    }
    Write-Host "Using parameter file: $parameterFile" -ForegroundColor Cyan

    $templateFile = Join-Path $repoRoot 'infra\main.bicep'
    if (-not (Test-Path $templateFile)) {
        throw "Bicep template not found: $templateFile"
    }

    # Create the resource group if it doesn't exist
    Write-Host "Checking resource group '$ResourceGroupName'..." -ForegroundColor Cyan
    $rgExists = az group exists --name $ResourceGroupName 2>&1
    if ($rgExists -ne 'true') {
        Write-Host "Creating resource group '$ResourceGroupName' in '$Location'..." -ForegroundColor Yellow
        az group create --name $ResourceGroupName --location $Location --output none
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create resource group '$ResourceGroupName'."
        }
        Write-Host "Resource group created." -ForegroundColor Green
    }
    else {
        Write-Host "Resource group '$ResourceGroupName' already exists." -ForegroundColor Green
    }

    # Build the deployment command
    $deployArgs = @(
        'deployment', 'group', 'create'
        '--resource-group', $ResourceGroupName
        '--template-file', $templateFile
        '--parameters', $parameterFile
        '--output', 'json'
    )

    if ($WhatIf) {
        $deployArgs += '--what-if'
        Write-Host "Running deployment in what-if mode..." -ForegroundColor Yellow
    }
    else {
        Write-Host "Starting deployment..." -ForegroundColor Cyan
    }

    $result = az @deployArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Deployment failed:`n$result"
    }

    Write-Host "`nDeployment completed successfully." -ForegroundColor Green
    Write-Output $result
}
catch {
    Write-Error "Deployment error: $_"
    exit 1
}
