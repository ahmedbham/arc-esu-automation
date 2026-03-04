<#
.SYNOPSIS
    Applies ESU licenses to eligible Azure Arc-connected machines.

.DESCRIPTION
    This Azure Automation runbook creates and assigns Extended Security Updates (ESU)
    licenses to Arc machines that are tagged ESU:Required (or specified via ResourceIds).
    Machines that already have an ESU license assignment are skipped.
    A structured summary of successes, skips, and failures is written to the job output.

.PARAMETER SubscriptionId
    Optional array of subscription IDs to scope the query for machines and licenses.
    If not specified, all subscriptions accessible by the Automation Account Managed Identity
    are scanned.

.PARAMETER ResourceIds
    Optional array of specific Arc machine resource IDs to process. If omitted, the
    runbook discovers all machines tagged ESU:Required.

.EXAMPLE
    .\Apply-EsuLicense.ps1

.EXAMPLE
    .\Apply-EsuLicense.ps1 -SubscriptionId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'

.EXAMPLE
    .\Apply-EsuLicense.ps1 -ResourceIds '/subscriptions/.../machines/server01','/subscriptions/.../machines/server02'

.NOTES
    This runbook depends on the EsuHelpers.psm1 module located in .\common\.
    Az modules (Az.Accounts, Az.ResourceGraph, Az.Resources, Az.ConnectedMachine)
    must be available in the Automation Account.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string[]]$SubscriptionId,

    [Parameter()]
    [string[]]$ResourceIds
)

try {
    # Import shared helper module
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'common\EsuHelpers.psm1'
    Write-Verbose "Importing helper module from: $modulePath"
    Import-Module $modulePath -Force -ErrorAction Stop

    # Authenticate via Managed Identity
    Write-Verbose "Authenticating to Azure..."
    Connect-AutomationAccount

    # Build splat for optional subscription scoping
    $splat = @{}
    if ($SubscriptionId) {
        $splat['SubscriptionId'] = $SubscriptionId
        Write-Verbose "Scoping to subscription(s): $($SubscriptionId -join ', ')"
    }

    # Determine target machines
    if ($ResourceIds) {
        Write-Verbose "Using $($ResourceIds.Count) explicitly provided resource ID(s)"
        $targetMachines = foreach ($rid in $ResourceIds) {
            try {
                $resource = Get-AzResource -ResourceId $rid -ErrorAction Stop
                [PSCustomObject]@{
                    id            = $resource.ResourceId
                    name          = $resource.Name
                    resourceGroup = $resource.ResourceGroupName
                    subscriptionId = ($resource.ResourceId -split '/')[2]
                    location      = $resource.Location
                    properties    = $resource.Properties
                }
            }
            catch {
                Write-Warning "Could not retrieve resource '$rid': $_"
            }
        }
        $targetMachines = @($targetMachines)
    }
    else {
        Write-Verbose "Discovering machines tagged ESU:Required..."
        $targetMachines = @(Get-ArcMachinesByTag -TagName 'ESU' -TagValue 'Required' @splat)
    }

    Write-Verbose "Target machines to process: $($targetMachines.Count)"

    if ($targetMachines.Count -eq 0) {
        Write-Output "No target machines found. Nothing to process."
        return
    }

    # Get existing ESU licenses to check for already-licensed machines
    Write-Verbose "Retrieving existing ESU licenses..."
    $existingLicenses = @(Get-ExistingEsuLicenses @splat)

    # Build lookup of machine IDs that already have a license assigned
    $licensedMachineIds = @{}
    foreach ($license in $existingLicenses) {
        $assignedMachineId = $license.properties.assignedMachineResourceId
        if ($assignedMachineId) {
            $licensedMachineIds[$assignedMachineId.ToLower()] = $license
        }
    }
    Write-Verbose "Found $($licensedMachineIds.Count) machine(s) with existing license assignments"

    # Process each target machine
    $created = @()
    $skipped = @()
    $failed = @()

    foreach ($machine in $targetMachines) {
        $machineName = $machine.name
        $machineId = $machine.id

        try {
            # Check if already licensed
            if ($licensedMachineIds.ContainsKey($machineId.ToLower())) {
                Write-Verbose "Machine '$machineName' already has an ESU license assigned — skipping"
                $skipped += [PSCustomObject]@{
                    Name          = $machineName
                    ResourceGroup = $machine.resourceGroup
                    Status        = 'AlreadyLicensed'
                    Reason        = 'Existing license found'
                }
                continue
            }

            # Extract OS info from machine properties
            $osName = $machine.properties.osName
            $osSku  = $machine.properties.osSku
            $processorCount = $machine.properties.detectedProperties.logicalCoreCount
            if (-not $processorCount -or $processorCount -lt 8) {
                $processorCount = 8   # minimum core count for ESU licensing
            }

            # Determine target OS edition
            $edition = 'Standard'
            if ($osSku -match 'Datacenter') {
                $edition = 'Datacenter'
            }

            Write-Verbose "Processing '$machineName': OS='$osName', SKU='$osSku', Edition='$edition', Cores=$processorCount"

            # Parse resource group and subscription from the machine resource ID
            $parts = $machineId -split '/'
            $machineSubscription = $parts[2]
            $machineResourceGroup = $machine.resourceGroup
            $machineLocation = $machine.location

            # Determine target OS type for the license
            $targetOs = 'WindowsServer2012'
            if ($osName -match '2012 R2' -or $osSku -match '2012 R2') {
                $targetOs = 'WindowsServer2012R2'
            }

            # Create the ESU license resource
            $licenseName = "esu-$machineName"
            Write-Verbose "Creating ESU license '$licenseName' in resource group '$machineResourceGroup'..."

            $licenseParams = @{
                Name              = $licenseName
                ResourceGroupName = $machineResourceGroup
                Location          = $machineLocation
                LicenseType       = 'ESU'
                State             = 'Activated'
                Target            = $targetOs
                Edition           = $edition
                Type              = 'pCore'
                ProcessorCount    = $processorCount
                SubscriptionId    = $machineSubscription
                ErrorAction       = 'Stop'
            }
            $newLicense = New-AzConnectedMachineLicense @licenseParams
            Write-Verbose "Created license '$licenseName' (ID: $($newLicense.Id))"

            # Assign the license to the machine
            Write-Verbose "Assigning license to machine '$machineName'..."
            $profileParams = @{
                MachineName       = $machineName
                ResourceGroupName = $machineResourceGroup
                LicenseResourceId = $newLicense.Id
                SubscriptionId    = $machineSubscription
                ErrorAction       = 'Stop'
            }
            $null = New-AzConnectedMachineLicenseProfile @profileParams
            Write-Verbose "License profile assigned to '$machineName'"

            # Enable Software Assurance on the machine
            Write-Verbose "Updating Software Assurance for machine '$machineName'..."
            $updateParams = @{
                Name              = $machineName
                ResourceGroupName = $machineResourceGroup
                SubscriptionId    = $machineSubscription
                LicenseProfileSoftwareAssuranceCustomer = $true
                ErrorAction       = 'Stop'
            }
            $null = Update-AzConnectedMachine @updateParams
            Write-Verbose "Software Assurance updated for '$machineName'"

            $created += [PSCustomObject]@{
                Name          = $machineName
                ResourceGroup = $machineResourceGroup
                Status        = 'LicenseCreated'
                LicenseName   = $licenseName
                Edition       = $edition
                Cores         = $processorCount
            }
        }
        catch {
            Write-Warning "Failed to apply ESU license to machine '$machineName': $_"
            $failed += [PSCustomObject]@{
                Name          = $machineName
                ResourceGroup = $machine.resourceGroup
                Status        = 'Failed'
                Error         = $_.Exception.Message
            }
        }
    }

    # Output summary
    $totalProcessed = $targetMachines.Count
    Write-Output "===== ESU License Application Summary ====="
    Write-Output "Total machines processed    : $totalProcessed"
    Write-Output "Licenses created            : $($created.Count)"
    Write-Output "Already licensed (skipped)  : $($skipped.Count)"
    Write-Output "Failures                    : $($failed.Count)"
    Write-Output "============================================"

    if ($created.Count -gt 0) {
        Write-Output ""
        Write-Output "Newly Licensed Machines:"
        Write-Output ($created | Format-Table Name, ResourceGroup, LicenseName, Edition, Cores -AutoSize | Out-String)
    }

    if ($skipped.Count -gt 0) {
        Write-Output ""
        Write-Output "Skipped Machines (Already Licensed):"
        Write-Output ($skipped | Format-Table Name, ResourceGroup, Reason -AutoSize | Out-String)
    }

    if ($failed.Count -gt 0) {
        Write-Output ""
        Write-Output "Failed Machines:"
        Write-Output ($failed | Format-Table Name, ResourceGroup, Error -AutoSize | Out-String)
    }

    Write-Verbose "Apply-EsuLicense runbook completed."
}
catch {
    Write-Error "ESU license application runbook failed: $_"
    throw
}
