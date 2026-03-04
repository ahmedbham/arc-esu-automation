<#
.SYNOPSIS
    Syncs ESU licenses with current Azure Arc machine state.

.DESCRIPTION
    This Azure Automation runbook detects decommissioned and recommissioned Arc machines
    and reconciles ESU license assignments accordingly.

    Decommission detection: finds licenses assigned to machines that no longer exist,
    are disconnected/expired, or have been tagged ESU:Excluded. Removes the license
    assignment and then the license resource.

    Recommission detection: finds eligible Arc machines that are Connected and tagged
    ESU:Required but don't have a license assigned. Outputs their resource IDs for
    the Apply-EsuLicense runbook to handle.

.PARAMETER SubscriptionId
    Optional array of subscription IDs to scope the sync. If not specified,
    all subscriptions accessible by the Automation Account Managed Identity are scanned.

.PARAMETER DryRun
    If set, reports planned changes without making them. Output is prefixed with "[DRY RUN]".

.EXAMPLE
    .\Sync-EsuLicenses.ps1

.EXAMPLE
    .\Sync-EsuLicenses.ps1 -DryRun

.EXAMPLE
    .\Sync-EsuLicenses.ps1 -SubscriptionId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' -DryRun

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
    [switch]$DryRun
)

$prefix = if ($DryRun) { '[DRY RUN] ' } else { '' }

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
        Write-Verbose "Scoping sync to subscription(s): $($SubscriptionId -join ', ')"
    }

    # Get current ESU-eligible machines
    Write-Verbose "Retrieving ESU-eligible Arc machines..."
    $eligibleMachines = @(Get-EsuEligibleMachines @splat)
    Write-Verbose "Found $($eligibleMachines.Count) eligible machine(s)"

    # Get existing ESU licenses
    Write-Verbose "Retrieving existing ESU licenses..."
    $existingLicenses = @(Get-ExistingEsuLicenses @splat)
    Write-Verbose "Found $($existingLicenses.Count) existing license(s)"

    # Build lookup sets for eligible machines
    $eligibleById = @{}
    foreach ($machine in $eligibleMachines) {
        $eligibleById[$machine.id.ToLower()] = $machine
    }

    # ── Decommission Detection ──────────────────────────────────────────────
    # Licenses assigned to machines that no longer exist, are disconnected/expired,
    # or have been tagged ESU:Excluded.
    Write-Verbose "Running decommission detection..."
    $licensesToRemove = @()

    foreach ($license in $existingLicenses) {
        $machineId = $license.properties.assignedMachineResourceId
        if (-not $machineId) {
            continue
        }

        $machineKey = $machineId.ToLower()
        $reason = $null

        if (-not $eligibleById.ContainsKey($machineKey)) {
            # Machine no longer exists in Arc or was excluded by eligibility logic
            $reason = 'Machine no longer exists or is excluded'
        }
        else {
            $machine = $eligibleById[$machineKey]
            $status = $machine.properties.status

            if ($status -and $status -ne 'Connected') {
                $reason = "Machine status is '$status' (not Connected)"
            }
            elseif ($machine.tags.ESU -eq 'Excluded') {
                $reason = 'Machine tagged ESU:Excluded'
            }
        }

        if ($reason) {
            $licensesToRemove += [PSCustomObject]@{
                LicenseId   = $license.id
                LicenseName = $license.name
                MachineId   = $machineId
                Reason      = $reason
            }
        }
    }

    Write-Verbose "Found $($licensesToRemove.Count) license(s) to decommission"

    # Process decommission removals
    $removedLicenses = @()
    $removalErrors = @()

    foreach ($item in $licensesToRemove) {
        try {
            Write-Output "${prefix}Removing license assignment for: $($item.LicenseName) (Reason: $($item.Reason))"

            if (-not $DryRun) {
                # Remove the license assignment from the machine
                $machineResourceName = ($item.MachineId -split '/')[-1]
                $machineResourceGroup = ($item.MachineId -split '/')[4]
                $machineSubscription = ($item.MachineId -split '/')[2]

                Remove-AzConnectedMachineLicenseProfile `
                    -MachineName $machineResourceName `
                    -ResourceGroupName $machineResourceGroup `
                    -SubscriptionId $machineSubscription `
                    -ErrorAction Stop

                Write-Verbose "License assignment removed from machine: $($item.MachineId)"

                # Remove the license resource
                $licenseResourceName = ($item.LicenseId -split '/')[-1]
                $licenseResourceGroup = ($item.LicenseId -split '/')[4]
                $licenseSubscription = ($item.LicenseId -split '/')[2]

                Remove-AzConnectedMachineLicense `
                    -Name $licenseResourceName `
                    -ResourceGroupName $licenseResourceGroup `
                    -SubscriptionId $licenseSubscription `
                    -ErrorAction Stop

                Write-Verbose "License resource removed: $($item.LicenseId)"
            }

            $removedLicenses += $item
        }
        catch {
            Write-Warning "${prefix}Failed to remove license '$($item.LicenseName)': $_"
            $removalErrors += [PSCustomObject]@{
                LicenseName = $item.LicenseName
                Error       = $_.ToString()
            }
        }
    }

    # ── Recommission Detection ──────────────────────────────────────────────
    # Eligible machines that are Connected, tagged ESU:Required, and don't have
    # a license assigned.
    Write-Verbose "Running recommission detection..."

    # Build set of machines that already have a license assigned
    $assignedMachineIds = @{}
    foreach ($license in $existingLicenses) {
        $mid = $license.properties.assignedMachineResourceId
        if ($mid) {
            $assignedMachineIds[$mid.ToLower()] = $true
        }
    }

    $machinesNeedingLicenses = @()

    foreach ($machine in $eligibleMachines) {
        $status = $machine.properties.status
        $esuTag = $machine.tags.ESU

        $isConnected = ($status -eq 'Connected')
        $isRequired = ($esuTag -eq 'Required')
        $hasLicense = $assignedMachineIds.ContainsKey($machine.id.ToLower())

        if ($isConnected -and $isRequired -and -not $hasLicense) {
            $machinesNeedingLicenses += [PSCustomObject]@{
                MachineId     = $machine.id
                MachineName   = $machine.name
                ResourceGroup = $machine.resourceGroup
                Subscription  = $machine.subscriptionId
            }
        }
    }

    Write-Verbose "Found $($machinesNeedingLicenses.Count) machine(s) needing license assignment"

    # ── Change Report ───────────────────────────────────────────────────────
    Write-Output ""
    Write-Output "${prefix}===== ESU License Sync Summary ====="
    Write-Output "${prefix}Licenses removed (decommissioned) : $($removedLicenses.Count)"
    Write-Output "${prefix}Removal errors                    : $($removalErrors.Count)"
    Write-Output "${prefix}Machines needing licenses         : $($machinesNeedingLicenses.Count)"
    Write-Output "${prefix}===================================="

    if ($removedLicenses.Count -gt 0) {
        Write-Output ""
        Write-Output "${prefix}Decommissioned Licenses:"
        $decommReport = $removedLicenses | ForEach-Object {
            [PSCustomObject]@{
                License = $_.LicenseName
                Machine = ($_.MachineId -split '/')[-1]
                Reason  = $_.Reason
            }
        }
        Write-Output ($decommReport | Format-Table -AutoSize | Out-String)
    }

    if ($removalErrors.Count -gt 0) {
        Write-Output ""
        Write-Output "${prefix}Removal Errors:"
        Write-Output ($removalErrors | Format-Table -AutoSize | Out-String)
    }

    if ($machinesNeedingLicenses.Count -gt 0) {
        Write-Output ""
        Write-Output "${prefix}Machines Needing License Assignment (for Apply-EsuLicense runbook):"
        $recommReport = $machinesNeedingLicenses | ForEach-Object {
            [PSCustomObject]@{
                Name          = $_.MachineName
                ResourceGroup = $_.ResourceGroup
                Subscription  = $_.Subscription
                ResourceId    = $_.MachineId
            }
        }
        Write-Output ($recommReport | Format-Table -AutoSize | Out-String)
    }

    Write-Verbose "Sync runbook completed successfully."
}
catch {
    Write-Error "ESU license sync runbook failed: $_"
    throw
}
