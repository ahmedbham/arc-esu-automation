<#
.SYNOPSIS
    Reports ESU compliance status for Azure Arc-connected machines.

.DESCRIPTION
    This Azure Automation runbook analyzes ESU compliance across Arc-connected machines
    by comparing eligible machines against existing ESU licenses. It generates structured
    JSON output suitable for Azure Monitor ingestion, including per-machine compliance
    status and aggregate metrics.

    Compliance categories:
    - Compliant: Eligible machine has a valid ESU license assigned.
    - NonCompliant: Eligible machine without an ESU license.
    - Orphaned: License assigned to a non-existent or non-eligible machine.
    - ExpiringSoon: License nearing expiration (within 30 days).

.PARAMETER SubscriptionId
    Optional array of subscription IDs to scope the report. If not specified,
    all subscriptions accessible by the Automation Account Managed Identity are scanned.

.EXAMPLE
    .\Report-EsuCompliance.ps1

.EXAMPLE
    .\Report-EsuCompliance.ps1 -SubscriptionId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'

.EXAMPLE
    .\Report-EsuCompliance.ps1 -SubscriptionId 'sub-id-1','sub-id-2' -Verbose

.NOTES
    This runbook depends on the EsuHelpers.psm1 module located in .\common\.
    Az modules (Az.Accounts, Az.ResourceGraph, Az.Resources) must be available
    in the Automation Account.
    Output is JSON formatted for Azure Monitor custom log ingestion.
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
        Write-Verbose "Scoping report to subscription(s): $($SubscriptionId -join ', ')"
    }

    # Gather data
    Write-Verbose "Retrieving ESU-eligible machines..."
    $eligibleMachines = @(Get-EsuEligibleMachines @splat)
    Write-Verbose "Found $($eligibleMachines.Count) ESU-eligible machine(s)"

    Write-Verbose "Retrieving existing ESU licenses..."
    $existingLicenses = @(Get-ExistingEsuLicenses @splat)
    Write-Verbose "Found $($existingLicenses.Count) existing ESU license(s)"

    # Build lookup: machine ID -> license (from existing licenses)
    $licensedMachineIds = @{}
    foreach ($license in $existingLicenses) {
        $assignedMachineId = $license.properties.assignedMachineResourceId
        if ($assignedMachineId) {
            $licensedMachineIds[$assignedMachineId.ToLower()] = $license
        }
    }

    # Build lookup of eligible machine IDs
    $eligibleMachineIds = @{}
    foreach ($machine in $eligibleMachines) {
        $eligibleMachineIds[$machine.id.ToLower()] = $true
    }

    # Analyze per-machine compliance by cross-referencing against license lookup
    $compliantMachines = @()
    $nonCompliantMachines = @()
    $machineDetails = @()

    foreach ($machine in $eligibleMachines) {
        $machineKey = $machine.id.ToLower()

        if ($licensedMachineIds.ContainsKey($machineKey)) {
            $compliantMachines += $machine
            $assignedLicense = $licensedMachineIds[$machineKey]
            $machineDetails += [PSCustomObject]@{
                Name             = $machine.name
                ResourceGroup    = $machine.resourceGroup
                SubscriptionId   = $machine.subscriptionId
                ComplianceStatus = 'Compliant'
                AssignedLicense  = $assignedLicense.id
            }
        }
        else {
            $nonCompliantMachines += $machine
            $machineDetails += [PSCustomObject]@{
                Name             = $machine.name
                ResourceGroup    = $machine.resourceGroup
                SubscriptionId   = $machine.subscriptionId
                ComplianceStatus = 'NonCompliant'
                AssignedLicense  = $null
            }
        }
    }

    # Identify orphaned licenses (assigned to machines not in eligible list)
    $orphanedLicenses = @()
    $expiringSoonLicenses = @()
    $expirationThresholdDays = 30

    foreach ($license in $existingLicenses) {
        $assignedMachineId = $license.properties.assignedMachineResourceId
        if ($assignedMachineId -and -not $eligibleMachineIds.ContainsKey($assignedMachineId.ToLower())) {
            $orphanedLicenses += $license
        }

        $endDate = $license.properties.licenseDetails.endDateTime
        if ($endDate) {
            $expiration = [datetime]::Parse($endDate)
            $daysRemaining = ($expiration - (Get-Date)).Days
            if ($daysRemaining -ge 0 -and $daysRemaining -le $expirationThresholdDays) {
                $expiringSoonLicenses += [PSCustomObject]@{
                    LicenseId      = $license.id
                    LicenseName    = $license.name
                    ExpirationDate = $endDate
                    DaysRemaining  = $daysRemaining
                }
            }
        }
    }

    # Calculate compliance metrics
    $totalEligible = $eligibleMachines.Count
    $compliantCount = $compliantMachines.Count
    $nonCompliantCount = $nonCompliantMachines.Count
    $orphanedCount = $orphanedLicenses.Count
    $compliancePercentage = if ($totalEligible -gt 0) {
        [math]::Round(($compliantCount / $totalEligible) * 100, 2)
    } else { 100.0 }

    Write-Verbose "Compliance analysis complete: $compliantCount/$totalEligible compliant ($compliancePercentage%)"
    Write-Verbose "Orphaned licenses: $orphanedCount"
    Write-Verbose "Licenses expiring within $expirationThresholdDays days: $($expiringSoonLicenses.Count)"

    # Build structured report for Azure Monitor ingestion
    $report = [PSCustomObject]@{
        ReportTimestamp       = (Get-Date -Format 'o')
        TotalEligibleMachines = $totalEligible
        CompliantCount        = $compliantCount
        CompliancePercentage  = $compliancePercentage
        NonCompliantCount     = $nonCompliantCount
        OrphanedLicenseCount  = $orphanedCount
        ExpiringSoonCount     = $expiringSoonLicenses.Count
        Machines              = $machineDetails
        OrphanedLicenses      = @($orphanedLicenses | ForEach-Object {
            [PSCustomObject]@{
                LicenseId     = $_.id
                LicenseName   = $_.name
                ResourceGroup = $_.resourceGroup
            }
        })
        ExpiringSoonLicenses  = $expiringSoonLicenses
    }

    Write-Output ($report | ConvertTo-Json -Depth 5)

    # Emit warnings and error marker for non-compliant machines
    if ($nonCompliantCount -gt 0) {
        foreach ($machine in $nonCompliantMachines) {
            Write-Warning "Non-compliant machine: '$($machine.name)' (RG: $($machine.resourceGroup), Sub: $($machine.subscriptionId)) - no ESU license assigned"
        }
        Write-Error "ESU_COMPLIANCE_ALERT: $nonCompliantCount of $totalEligible eligible machine(s) are non-compliant."
    }

    Write-Verbose "ESU compliance report completed successfully."
}
catch {
    Write-Error "ESU compliance report runbook failed: $_"
    throw
}
