#Requires -Modules Az.Accounts, Az.ResourceGraph, Az.Resources

<#
.SYNOPSIS
    Shared helper module for Azure Arc ESU automation runbooks.

.DESCRIPTION
    Provides common functions for authenticating, querying Arc machines,
    managing ESU eligibility, and working with ESU licenses.
#>

function Connect-AutomationAccount {
    <#
    .SYNOPSIS
        Authenticates to Azure using Managed Identity.

    .DESCRIPTION
        Connects to Azure using the Managed Identity assigned to the Automation Account.
        Throws on failure so callers can handle the error.

    .EXAMPLE
        Connect-AutomationAccount
    #>
    [CmdletBinding()]
    param()

    try {
        Write-Verbose "Connecting to Azure using Managed Identity..."
        $null = Connect-AzAccount -Identity -ErrorAction Stop
        Write-Verbose "Successfully connected to Azure."
    }
    catch {
        throw "Failed to connect using Managed Identity: $_"
    }
}

function Get-ArcMachinesByTag {
    <#
    .SYNOPSIS
        Queries Azure Resource Graph for Arc machines filtered by a specific tag.

    .DESCRIPTION
        Uses Search-AzGraph to find Microsoft.HybridCompute/machines resources
        that have the specified tag name and value.

    .PARAMETER TagName
        The tag name to filter on.

    .PARAMETER TagValue
        The tag value to filter on.

    .PARAMETER SubscriptionId
        Optional array of subscription IDs to scope the query.

    .EXAMPLE
        Get-ArcMachinesByTag -TagName 'ESU' -TagValue 'Required'

    .EXAMPLE
        Get-ArcMachinesByTag -TagName 'Environment' -TagValue 'Production' -SubscriptionId 'sub-id-1','sub-id-2'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TagName,

        [Parameter(Mandatory)]
        [string]$TagValue,

        [Parameter()]
        [string[]]$SubscriptionId
    )

    try {
        $escapedTagName = $TagName.Replace("'", "''")
        $escapedTagValue = $TagValue.Replace("'", "''")

        $query = @"
Resources
| where type =~ 'Microsoft.HybridCompute/machines'
| where tags['$escapedTagName'] =~ '$escapedTagValue'
| project id, name, resourceGroup, subscriptionId, location, tags, properties
"@

        Write-Verbose "Querying Resource Graph for Arc machines with tag $TagName=$TagValue"

        $params = @{
            Query      = $query
            ErrorAction = 'Stop'
        }
        if ($SubscriptionId) {
            $params['Subscription'] = $SubscriptionId
        }

        $results = [System.Collections.ArrayList]::new()
        $skipToken = $null
        do {
            if ($skipToken) {
                $params['SkipToken'] = $skipToken
            }
            $response = Search-AzGraph @params
            [void]$results.AddRange($response.Data)
            $skipToken = $response.SkipToken
        } while ($skipToken)

        Write-Verbose "Found $($results.Count) Arc machine(s) with tag $TagName=$TagValue"
        return ,$results
    }
    catch {
        throw "Failed to query Arc machines by tag ($TagName=$TagValue): $_"
    }
}

function Get-ArcMachinesByOs {
    <#
    .SYNOPSIS
        Queries Azure Resource Graph for Arc machines running ESU-eligible OS versions.

    .DESCRIPTION
        Finds Arc machines running Windows Server 2012 or Windows Server 2012 R2
        by filtering on properties.osName or properties.osSku containing "2012".

    .PARAMETER SubscriptionId
        Optional array of subscription IDs to scope the query.

    .EXAMPLE
        Get-ArcMachinesByOs

    .EXAMPLE
        Get-ArcMachinesByOs -SubscriptionId 'sub-id-1'
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string[]]$SubscriptionId
    )

    try {
        $query = @"
Resources
| where type =~ 'Microsoft.HybridCompute/machines'
| where properties.osName contains '2012' or properties.osSku contains '2012'
| project id, name, resourceGroup, subscriptionId, location, tags, properties
"@

        Write-Verbose "Querying Resource Graph for Arc machines with ESU-eligible OS (2012/R2)"

        $params = @{
            Query       = $query
            ErrorAction = 'Stop'
        }
        if ($SubscriptionId) {
            $params['Subscription'] = $SubscriptionId
        }

        $results = [System.Collections.ArrayList]::new()
        $skipToken = $null
        do {
            if ($skipToken) {
                $params['SkipToken'] = $skipToken
            }
            $response = Search-AzGraph @params
            [void]$results.AddRange($response.Data)
            $skipToken = $response.SkipToken
        } while ($skipToken)

        Write-Verbose "Found $($results.Count) Arc machine(s) with ESU-eligible OS"
        return ,$results
    }
    catch {
        throw "Failed to query Arc machines by OS: $_"
    }
}

function Get-EsuEligibleMachines {
    <#
    .SYNOPSIS
        Returns the combined set of ESU-eligible Arc machines.

    .DESCRIPTION
        Combines OS-based detection with tag overrides to produce the final list
        of eligible machines:
        1. Get machines by OS (Windows Server 2012 / 2012 R2)
        2. Force-include machines tagged ESU:Required
        3. Force-exclude machines tagged ESU:Excluded
        4. De-duplicate by resource ID

    .PARAMETER SubscriptionId
        Optional array of subscription IDs to scope the query.

    .EXAMPLE
        Get-EsuEligibleMachines

    .EXAMPLE
        $machines = Get-EsuEligibleMachines -SubscriptionId 'sub-id-1' -Verbose
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string[]]$SubscriptionId
    )

    try {
        $splat = @{}
        if ($SubscriptionId) {
            $splat['SubscriptionId'] = $SubscriptionId
        }

        # Step 1: Get machines by OS
        Write-Verbose "Step 1: Querying machines by ESU-eligible OS..."
        $osMachines = @(Get-ArcMachinesByOs @splat)

        # Step 2: Force-include machines tagged ESU:Required
        Write-Verbose "Step 2: Querying machines tagged ESU:Required..."
        $forceInclude = @(Get-ArcMachinesByTag -TagName 'ESU' -TagValue 'Required' @splat)

        # Step 3: Force-exclude machines tagged ESU:Excluded
        Write-Verbose "Step 3: Querying machines tagged ESU:Excluded..."
        $forceExclude = @(Get-ArcMachinesByTag -TagName 'ESU' -TagValue 'Excluded' @splat)

        # Build exclusion set
        $excludedIds = @{}
        foreach ($machine in $forceExclude) {
            $excludedIds[$machine.id.ToLower()] = $true
        }

        # Step 4: Merge and de-duplicate by resource ID
        Write-Verbose "Step 4: Merging and de-duplicating results..."
        $seen = @{}
        $eligible = @()

        foreach ($machine in ($osMachines + $forceInclude)) {
            $key = $machine.id.ToLower()
            if (-not $seen.ContainsKey($key) -and -not $excludedIds.ContainsKey($key)) {
                $seen[$key] = $true
                $eligible += $machine
            }
        }

        Write-Verbose "Total eligible machines: $($eligible.Count) (OS-based: $($osMachines.Count), force-included: $($forceInclude.Count), force-excluded: $($forceExclude.Count))"
        return $eligible
    }
    catch {
        throw "Failed to determine ESU-eligible machines: $_"
    }
}

function Get-ExistingEsuLicenses {
    <#
    .SYNOPSIS
        Queries Azure Resource Graph for existing ESU license resources.

    .DESCRIPTION
        Finds Microsoft.HybridCompute/licenses resources and returns them
        with their assignment information.

    .PARAMETER SubscriptionId
        Optional array of subscription IDs to scope the query.

    .EXAMPLE
        Get-ExistingEsuLicenses

    .EXAMPLE
        Get-ExistingEsuLicenses -SubscriptionId 'sub-id-1','sub-id-2'
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string[]]$SubscriptionId
    )

    try {
        $query = @"
Resources
| where type =~ 'Microsoft.HybridCompute/licenses'
| project id, name, resourceGroup, subscriptionId, location, tags, properties
"@

        Write-Verbose "Querying Resource Graph for existing ESU licenses"

        $params = @{
            Query       = $query
            ErrorAction = 'Stop'
        }
        if ($SubscriptionId) {
            $params['Subscription'] = $SubscriptionId
        }

        $results = [System.Collections.ArrayList]::new()
        $skipToken = $null
        do {
            if ($skipToken) {
                $params['SkipToken'] = $skipToken
            }
            $response = Search-AzGraph @params
            [void]$results.AddRange($response.Data)
            $skipToken = $response.SkipToken
        } while ($skipToken)

        Write-Verbose "Found $($results.Count) existing ESU license(s)"
        return ,$results
    }
    catch {
        throw "Failed to query existing ESU licenses: $_"
    }
}

function Set-MachineEsuTag {
    <#
    .SYNOPSIS
        Tags an Arc machine with an ESU-related tag.

    .DESCRIPTION
        Applies a tag to the specified Arc machine resource using Update-AzTag
        with a Merge operation. Defaults to ESU:Required.

    .PARAMETER ResourceId
        The full Azure resource ID of the Arc machine.

    .PARAMETER TagName
        The tag name to set. Defaults to 'ESU'.

    .PARAMETER TagValue
        The tag value to set. Defaults to 'Required'.

    .EXAMPLE
        Set-MachineEsuTag -ResourceId '/subscriptions/.../machines/myServer'

    .EXAMPLE
        Set-MachineEsuTag -ResourceId '/subscriptions/.../machines/myServer' -TagName 'ESU' -TagValue 'Excluded'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceId,

        [Parameter()]
        [string]$TagName = 'ESU',

        [Parameter()]
        [string]$TagValue = 'Required'
    )

    try {
        Write-Verbose "Setting tag $TagName=$TagValue on resource: $ResourceId"

        $tags = @{ $TagName = $TagValue }
        $null = Update-AzTag -ResourceId $ResourceId -Tag $tags -Operation Merge -ErrorAction Stop

        Write-Verbose "Successfully tagged resource: $ResourceId"
    }
    catch {
        throw "Failed to set tag $TagName=$TagValue on resource $ResourceId`: $_"
    }
}

Export-ModuleMember -Function @(
    'Connect-AutomationAccount'
    'Get-ArcMachinesByTag'
    'Get-ArcMachinesByOs'
    'Get-EsuEligibleMachines'
    'Get-ExistingEsuLicenses'
    'Set-MachineEsuTag'
)
