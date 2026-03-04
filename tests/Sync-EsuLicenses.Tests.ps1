#Requires -Module Pester

BeforeAll {
    # Stub Az cmdlets and module functions so the script can be dot-sourced
    function Connect-AzAccount { }
    function Search-AzGraph { [PSCustomObject]@{ Data = @(); SkipToken = $null } }
    function Update-AzTag { }
    function Connect-AutomationAccount { }
    function Get-EsuEligibleMachines { param([string[]]$SubscriptionId) }
    function Get-ExistingEsuLicenses { param([string[]]$SubscriptionId) }
    function Get-ArcMachinesByTag { param([Parameter(Mandatory)][string]$TagName, [Parameter(Mandatory)][string]$TagValue, [string[]]$SubscriptionId) }
    function Get-ArcMachinesByOs { param([string[]]$SubscriptionId) }
    function Remove-AzConnectedMachineLicenseProfile { param($MachineName, $ResourceGroupName, $SubscriptionId, $ErrorAction) }
    function Remove-AzConnectedMachineLicense { param($Name, $ResourceGroupName, $SubscriptionId, $ErrorAction) }

    $scriptPath = Join-Path $PSScriptRoot '..\runbooks\Sync-EsuLicenses.ps1'
}

Describe 'Sync-EsuLicenses' {

    BeforeEach {
        Mock Import-Module { }
        Mock Connect-AutomationAccount { }
        Mock Write-Output { }
        Mock Write-Verbose { }
        Mock Write-Warning { }
        Mock Remove-AzConnectedMachineLicenseProfile { }
        Mock Remove-AzConnectedMachineLicense { }
    }

    Context 'When a decommissioned machine is detected' {

        BeforeEach {
            # License assigned to a machine that is no longer in the eligible set
            $licenses = @(
                [PSCustomObject]@{
                    id         = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.HybridCompute/licenses/esu-oldServer'
                    name       = 'esu-oldServer'
                    resourceGroup = 'rg1'
                    properties = @{
                        assignedMachineResourceId = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.HybridCompute/machines/oldServer'
                    }
                }
            )
            Mock Get-EsuEligibleMachines { @() }
            Mock Get-ExistingEsuLicenses { $licenses }
        }

        It 'Should remove the license profile from the decommissioned machine' {
            & $scriptPath

            Should -Invoke Remove-AzConnectedMachineLicenseProfile -Times 1 -Exactly
        }

        It 'Should remove the license resource' {
            & $scriptPath

            Should -Invoke Remove-AzConnectedMachineLicense -Times 1 -Exactly
        }
    }

    Context 'When a recommissioned machine needs a license' {

        BeforeEach {
            $machines = @(
                [PSCustomObject]@{
                    id            = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.HybridCompute/machines/newServer'
                    name          = 'newServer'
                    resourceGroup = 'rg1'
                    subscriptionId = 'sub1'
                    location      = 'eastus'
                    tags          = @{ ESU = 'Required' }
                    properties    = @{ status = 'Connected' }
                }
            )
            Mock Get-EsuEligibleMachines { $machines }
            Mock Get-ExistingEsuLicenses { @() }
        }

        It 'Should identify the machine as needing a license in the output' {
            & $scriptPath

            Should -Invoke Write-Output -ParameterFilter {
                $InputObject -like '*Machines Needing License*'
            } -Times 1
        }

        It 'Should not call any removal commands' {
            & $scriptPath

            Should -Invoke Remove-AzConnectedMachineLicenseProfile -Times 0 -Exactly
            Should -Invoke Remove-AzConnectedMachineLicense -Times 0 -Exactly
        }
    }

    Context 'When DryRun mode is enabled' {

        BeforeEach {
            $licenses = @(
                [PSCustomObject]@{
                    id         = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.HybridCompute/licenses/esu-goneServer'
                    name       = 'esu-goneServer'
                    resourceGroup = 'rg1'
                    properties = @{
                        assignedMachineResourceId = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.HybridCompute/machines/goneServer'
                    }
                }
            )
            Mock Get-EsuEligibleMachines { @() }
            Mock Get-ExistingEsuLicenses { $licenses }
        }

        It 'Should not remove any license profiles or resources' {
            & $scriptPath -DryRun

            Should -Invoke Remove-AzConnectedMachineLicenseProfile -Times 0 -Exactly
            Should -Invoke Remove-AzConnectedMachineLicense -Times 0 -Exactly
        }

        It 'Should include DRY RUN prefix in output' {
            & $scriptPath -DryRun

            Should -Invoke Write-Output -ParameterFilter {
                $InputObject -like '*`[DRY RUN`]*'
            }
        }
    }

    Context 'When no eligible machines or licenses exist' {

        BeforeEach {
            Mock Get-EsuEligibleMachines { @() }
            Mock Get-ExistingEsuLicenses { @() }
        }

        It 'Should complete without errors' {
            { & $scriptPath } | Should -Not -Throw
        }

        It 'Should not call any removal commands' {
            & $scriptPath

            Should -Invoke Remove-AzConnectedMachineLicenseProfile -Times 0 -Exactly
            Should -Invoke Remove-AzConnectedMachineLicense -Times 0 -Exactly
        }
    }
}
