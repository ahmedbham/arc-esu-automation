#Requires -Module Pester

BeforeAll {
    # Stub Az cmdlets and module functions so the script can be dot-sourced
    function Connect-AzAccount { }
    function Search-AzGraph { [PSCustomObject]@{ Data = @(); SkipToken = $null } }
    function Update-AzTag { }
    function Get-EsuEligibleMachines { param([string[]]$SubscriptionId) }
    function Set-MachineEsuTag { param([Parameter(Mandatory)][string]$ResourceId, [string]$TagName = 'ESU', [string]$TagValue = 'Required') }
    function Connect-AutomationAccount { }
    function Get-ArcMachinesByTag { param([Parameter(Mandatory)][string]$TagName, [Parameter(Mandatory)][string]$TagValue, [string[]]$SubscriptionId) }
    function Get-ArcMachinesByOs { param([string[]]$SubscriptionId) }

    # Dot-source the runbook under test
    $scriptPath = Join-Path $PSScriptRoot '..\runbooks\Discover-ArcEsuMachines.ps1'
}

Describe 'Discover-ArcEsuMachines' {

    BeforeEach {
        # Default mocks — happy-path stubs
        Mock Import-Module { }
        Mock Connect-AutomationAccount { }
        Mock Set-MachineEsuTag { }
        Mock Write-Output { }
        Mock Write-Verbose { }
    }

    Context 'When eligible machines are found that are not yet tagged' {

        BeforeEach {
            $machines = @(
                [PSCustomObject]@{
                    id            = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.HybridCompute/machines/server01'
                    name          = 'server01'
                    resourceGroup = 'rg1'
                    subscriptionId = 'sub1'
                    location      = 'eastus'
                    tags          = @{}
                    properties    = @{ osName = 'Windows Server 2012 R2' }
                },
                [PSCustomObject]@{
                    id            = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.HybridCompute/machines/server02'
                    name          = 'server02'
                    resourceGroup = 'rg1'
                    subscriptionId = 'sub1'
                    location      = 'eastus'
                    tags          = @{}
                    properties    = @{ osName = 'Windows Server 2012' }
                }
            )
            Mock Get-EsuEligibleMachines { $machines }
        }

        It 'Should call Set-MachineEsuTag for each untagged machine' {
            & $scriptPath

            Should -Invoke Set-MachineEsuTag -Times 2 -Exactly
        }

        It 'Should pass the correct ResourceId to Set-MachineEsuTag' {
            & $scriptPath

            Should -Invoke Set-MachineEsuTag -ParameterFilter {
                $ResourceId -eq '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.HybridCompute/machines/server01'
            } -Times 1
            Should -Invoke Set-MachineEsuTag -ParameterFilter {
                $ResourceId -eq '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.HybridCompute/machines/server02'
            } -Times 1
        }
    }

    Context 'When machines are already tagged ESU:Required' {

        BeforeEach {
            $machines = @(
                [PSCustomObject]@{
                    id            = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.HybridCompute/machines/server01'
                    name          = 'server01'
                    resourceGroup = 'rg1'
                    subscriptionId = 'sub1'
                    location      = 'eastus'
                    tags          = @{ ESU = 'Required' }
                    properties    = @{ osName = 'Windows Server 2012 R2' }
                }
            )
            Mock Get-EsuEligibleMachines { $machines }
        }

        It 'Should skip machines already tagged and not call Set-MachineEsuTag' {
            & $scriptPath

            Should -Invoke Set-MachineEsuTag -Times 0 -Exactly
        }
    }

    Context 'When no eligible machines are found' {

        BeforeEach {
            Mock Get-EsuEligibleMachines { @() }
        }

        It 'Should handle empty machine list gracefully without errors' {
            { & $scriptPath } | Should -Not -Throw
        }

        It 'Should not call Set-MachineEsuTag' {
            & $scriptPath

            Should -Invoke Set-MachineEsuTag -Times 0 -Exactly
        }
    }

    Context 'When SubscriptionId parameter is provided' {

        BeforeEach {
            Mock Get-EsuEligibleMachines { @() }
        }

        It 'Should pass SubscriptionId to Get-EsuEligibleMachines' {
            & $scriptPath -SubscriptionId 'sub-123'

            Should -Invoke Get-EsuEligibleMachines -ParameterFilter {
                $SubscriptionId -contains 'sub-123'
            } -Times 1
        }

        It 'Should pass multiple SubscriptionIds correctly' {
            & $scriptPath -SubscriptionId 'sub-1', 'sub-2'

            Should -Invoke Get-EsuEligibleMachines -ParameterFilter {
                $SubscriptionId -contains 'sub-1' -and $SubscriptionId -contains 'sub-2'
            } -Times 1
        }
    }
}
