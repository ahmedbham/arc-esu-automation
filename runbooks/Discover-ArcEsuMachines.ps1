<#
.SYNOPSIS
    Discovers Azure Arc machines that are eligible for Extended Security Updates (ESU).

.DESCRIPTION
    This Azure Automation runbook scans Azure Arc-connected machines to identify those
    eligible for ESU (Windows Server 2012 / 2012 R2) using OS detection and tag overrides.
    Machines that don't already have the ESU:Required tag are automatically tagged.
    A structured summary is written to the job output.

.PARAMETER SubscriptionId
    Optional array of subscription IDs to scope the discovery. If not specified,
    all subscriptions accessible by the Automation Account Managed Identity are scanned.

.EXAMPLE
    .\Discover-ArcEsuMachines.ps1

.EXAMPLE
    .\Discover-ArcEsuMachines.ps1 -SubscriptionId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'

.EXAMPLE
    .\Discover-ArcEsuMachines.ps1 -SubscriptionId 'sub-id-1','sub-id-2' -Verbose

.NOTES
    This runbook depends on the EsuHelpers.psm1 module located in .\common\.
    Az modules (Az.Accounts, Az.ResourceGraph, Az.Resources) must be available
    in the Automation Account.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string[]]$SubscriptionId
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
        Write-Verbose "Scoping discovery to subscription(s): $($SubscriptionId -join ', ')"
    }

    # Discover ESU-eligible machines
    Write-Verbose "Discovering ESU-eligible Arc machines..."
    $eligibleMachines = @(Get-EsuEligibleMachines @splat)
    $totalScanned = $eligibleMachines.Count

    Write-Verbose "Found $totalScanned ESU-eligible machine(s)"

    # Tag machines that don't already have ESU:Required
    $newlyTagged = @()
    foreach ($machine in $eligibleMachines) {
        $currentEsuTag = $machine.tags.ESU
        if ($currentEsuTag -ne 'Required') {
            Write-Verbose "Tagging machine '$($machine.name)' (RG: $($machine.resourceGroup)) with ESU:Required"
            Set-MachineEsuTag -ResourceId $machine.id
            $newlyTagged += $machine
        }
        else {
            Write-Verbose "Machine '$($machine.name)' already tagged ESU:Required — skipping"
        }
    }

    # Build structured summary
    $machineList = $eligibleMachines | ForEach-Object {
        [PSCustomObject]@{
            Name          = $_.name
            ResourceGroup = $_.resourceGroup
            Subscription  = $_.subscriptionId
            EsuTagStatus  = if ($_.tags.ESU -eq 'Required' -and $_ -notin $newlyTagged) { 'Already Tagged' } else { 'Newly Tagged' }
        }
    }

    $summary = [PSCustomObject]@{
        TotalEsuEligible   = $totalScanned
        NewlyTaggedCount   = $newlyTagged.Count
        AlreadyTaggedCount = $totalScanned - $newlyTagged.Count
        Machines           = $machineList
    }

    Write-Output "===== ESU Discovery Summary ====="
    Write-Output "ESU-eligible machines found : $($summary.TotalEsuEligible)"
    Write-Output "Newly tagged               : $($summary.NewlyTaggedCount)"
    Write-Output "Already tagged             : $($summary.AlreadyTaggedCount)"
    Write-Output "================================="

    if ($machineList.Count -gt 0) {
        Write-Output ""
        Write-Output "Machine Details:"
        Write-Output ($machineList | Format-Table -AutoSize | Out-String)
    }

    Write-Verbose "Discovery runbook completed successfully."
}
catch {
    Write-Error "ESU discovery runbook failed: $_"
    throw
}
