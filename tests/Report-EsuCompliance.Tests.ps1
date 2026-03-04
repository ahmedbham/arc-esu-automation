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

    $scriptPath = Join-Path $PSScriptRoot '..\runbooks\Report-EsuCompliance.ps1'
}

Describe 'Report-EsuCompliance' {

    BeforeEach {
        Mock Import-Module { }
        Mock Connect-AutomationAccount { }
        Mock Write-Verbose { }
        Mock Write-Warning { }
        Mock Write-Error { }
    }

    Context 'When identifying compliant vs non-compliant machines' {

        BeforeEach {
            $machines = @(
                # Compliant: machine ID matches a license's assignedMachineResourceId
                [PSCustomObject]@{
                    id            = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.HybridCompute/machines/compliantServer'
                    name          = 'compliantServer'
                    resourceGroup = 'rg1'
                    subscriptionId = 'sub1'
                    properties    = @{ osName = 'Windows Server 2012 R2' }
                },
                # Non-compliant: no license references this machine
                [PSCustomObject]@{
                    id            = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.HybridCompute/machines/nonCompliantServer'
                    name          = 'nonCompliantServer'
                    resourceGroup = 'rg1'
                    subscriptionId = 'sub1'
                    properties    = @{ osName = 'Windows Server 2012' }
                }
            )
            $licenses = @(
                [PSCustomObject]@{
                    id            = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.HybridCompute/licenses/lic1'
                    name          = 'lic1'
                    resourceGroup = 'rg1'
                    properties    = @{
                        assignedMachineResourceId = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.HybridCompute/machines/compliantServer'
                        licenseDetails = @{ endDateTime = $null }
                    }
                }
            )
            Mock Get-EsuEligibleMachines { $machines }
            Mock Get-ExistingEsuLicenses { $licenses }
        }

        It 'Should report CompliantCount = 1 and NonCompliantCount = 1' {
            $output = & $scriptPath

            $report = $output | ConvertFrom-Json
            $report.CompliantCount | Should -Be 1
            $report.NonCompliantCount | Should -Be 1
        }

        It 'Should calculate correct compliance percentage' {
            $output = & $scriptPath

            $report = $output | ConvertFrom-Json
            $report.CompliancePercentage | Should -Be 50.0
        }
    }

    Context 'When orphaned licenses exist' {

        BeforeEach {
            # No eligible machines, but one license assigned to a non-existent machine — it's orphaned
            Mock Get-EsuEligibleMachines { @() }
            $licenses = @(
                [PSCustomObject]@{
                    id            = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.HybridCompute/licenses/orphanLic'
                    name          = 'orphanLic'
                    resourceGroup = 'rg1'
                    properties    = @{
                        assignedMachineResourceId = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.HybridCompute/machines/deletedServer'
                        licenseDetails = @{ endDateTime = $null }
                    }
                }
            )
            Mock Get-ExistingEsuLicenses { $licenses }
        }

        It 'Should detect the orphaned license' {
            $output = & $scriptPath

            $report = $output | ConvertFrom-Json
            $report.OrphanedLicenseCount | Should -Be 1
            $report.OrphanedLicenses[0].LicenseName | Should -Be 'orphanLic'
        }
    }

    Context 'Output format validation' {

        BeforeEach {
            Mock Get-EsuEligibleMachines { @() }
            Mock Get-ExistingEsuLicenses { @() }
        }

        It 'Should output valid JSON' {
            $output = & $scriptPath

            { $output | ConvertFrom-Json } | Should -Not -Throw
        }

        It 'Should include ReportTimestamp in the output' {
            $output = & $scriptPath

            $report = $output | ConvertFrom-Json
            $report.ReportTimestamp | Should -Not -BeNullOrEmpty
        }
    }

    Context 'When non-compliant machines are found' {

        BeforeEach {
            $machines = @(
                [PSCustomObject]@{
                    id            = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.HybridCompute/machines/badServer'
                    name          = 'badServer'
                    resourceGroup = 'rg1'
                    subscriptionId = 'sub1'
                    properties    = @{ osName = 'Windows Server 2012' }
                }
            )
            Mock Get-EsuEligibleMachines { $machines }
            Mock Get-ExistingEsuLicenses { @() }
        }

        It 'Should write a warning for each non-compliant machine' {
            $null = & $scriptPath

            Should -Invoke Write-Warning -ParameterFilter {
                $Message -like "*badServer*"
            } -Times 1 -Exactly
        }

        It 'Should emit an ESU_COMPLIANCE_ALERT error' {
            $null = & $scriptPath

            Should -Invoke Write-Error -ParameterFilter {
                $Message -like '*ESU_COMPLIANCE_ALERT*'
            } -Times 1 -Exactly
        }
    }
}
