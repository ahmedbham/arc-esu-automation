#Requires -Module Pester

BeforeAll {
    # Stub Az cmdlets and module functions so the script can be dot-sourced
    function Connect-AzAccount { }
    function Search-AzGraph { [PSCustomObject]@{ Data = @(); SkipToken = $null } }
    function Update-AzTag { }
    function Connect-AutomationAccount { }
    function Get-ArcMachinesByTag { param([Parameter(Mandatory)][string]$TagName, [Parameter(Mandatory)][string]$TagValue, [string[]]$SubscriptionId) }
    function Get-ExistingEsuLicenses { param([string[]]$SubscriptionId) }
    function New-AzConnectedMachineLicense { param($Name, $ResourceGroupName, $Location, $LicenseType, $State, $Target, $Edition, $Type, $ProcessorCount, $SubscriptionId, $ErrorAction) }
    function New-AzConnectedMachineLicenseProfile { param($MachineName, $ResourceGroupName, $LicenseResourceId, $SubscriptionId, $ErrorAction) }
    function Update-AzConnectedMachine { param($Name, $ResourceGroupName, $SubscriptionId, $LicenseProfileSoftwareAssuranceCustomer, $ErrorAction) }
    function Get-AzResource { param($ResourceId, $ErrorAction) }

    $scriptPath = Join-Path $PSScriptRoot '..\runbooks\Apply-EsuLicense.ps1'
}

Describe 'Apply-EsuLicense' {

    BeforeEach {
        Mock Import-Module { }
        Mock Connect-AutomationAccount { }
        Mock Get-ArcMachinesByTag { }
        Mock Get-ExistingEsuLicenses { @() }
        Mock Write-Output { }
        Mock Write-Verbose { }
        Mock Write-Warning { }
    }

    Context 'When machines need new licenses' {

        BeforeEach {
            $machines = @(
                [PSCustomObject]@{
                    id            = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.HybridCompute/machines/server01'
                    name          = 'server01'
                    resourceGroup = 'rg1'
                    subscriptionId = 'sub1'
                    location      = 'eastus'
                    properties    = @{
                        osName = 'Windows Server 2012 R2'
                        osSku  = 'Standard'
                        detectedProperties = @{ logicalCoreCount = 16 }
                    }
                }
            )
            Mock Get-ArcMachinesByTag { $machines }
            Mock Get-ExistingEsuLicenses { @() }
            Mock New-AzConnectedMachineLicense {
                [PSCustomObject]@{ Id = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.HybridCompute/licenses/esu-server01' }
            }
            Mock New-AzConnectedMachineLicenseProfile { }
            Mock Update-AzConnectedMachine { }
        }

        It 'Should create a license for the machine' {
            & $scriptPath

            Should -Invoke New-AzConnectedMachineLicense -Times 1 -Exactly
        }

        It 'Should assign the license profile to the machine' {
            & $scriptPath

            Should -Invoke New-AzConnectedMachineLicenseProfile -Times 1 -Exactly -ParameterFilter {
                $MachineName -eq 'server01'
            }
        }

        It 'Should enable Software Assurance on the machine' {
            & $scriptPath

            Should -Invoke Update-AzConnectedMachine -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'server01'
            }
        }
    }

    Context 'When machines already have licenses' {

        BeforeEach {
            $machines = @(
                [PSCustomObject]@{
                    id            = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.HybridCompute/machines/server01'
                    name          = 'server01'
                    resourceGroup = 'rg1'
                    subscriptionId = 'sub1'
                    location      = 'eastus'
                    properties    = @{ osName = 'Windows Server 2012 R2'; osSku = 'Standard' }
                }
            )
            $licenses = @(
                [PSCustomObject]@{
                    id         = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.HybridCompute/licenses/esu-server01'
                    name       = 'esu-server01'
                    properties = @{
                        assignedMachineResourceId = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.HybridCompute/machines/server01'
                    }
                }
            )
            Mock Get-ArcMachinesByTag { $machines }
            Mock Get-ExistingEsuLicenses { $licenses }
            Mock New-AzConnectedMachineLicense { }
        }

        It 'Should skip already-licensed machines and not create a new license' {
            & $scriptPath

            Should -Invoke New-AzConnectedMachineLicense -Times 0 -Exactly
        }
    }

    Context 'When an individual machine fails during license creation' {

        BeforeEach {
            $machines = @(
                [PSCustomObject]@{
                    id            = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.HybridCompute/machines/failServer'
                    name          = 'failServer'
                    resourceGroup = 'rg1'
                    subscriptionId = 'sub1'
                    location      = 'eastus'
                    properties    = @{
                        osName = 'Windows Server 2012'
                        osSku  = 'Standard'
                        detectedProperties = @{ logicalCoreCount = 8 }
                    }
                },
                [PSCustomObject]@{
                    id            = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.HybridCompute/machines/goodServer'
                    name          = 'goodServer'
                    resourceGroup = 'rg1'
                    subscriptionId = 'sub1'
                    location      = 'eastus'
                    properties    = @{
                        osName = 'Windows Server 2012'
                        osSku  = 'Datacenter'
                        detectedProperties = @{ logicalCoreCount = 8 }
                    }
                }
            )
            Mock Get-ArcMachinesByTag { $machines }
            Mock Get-ExistingEsuLicenses { @() }
            Mock New-AzConnectedMachineLicense {
                if ($Name -eq 'esu-failServer') { throw 'Simulated Azure API error' }
                [PSCustomObject]@{ Id = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.HybridCompute/licenses/esu-goodServer' }
            }
            Mock New-AzConnectedMachineLicenseProfile { }
            Mock Update-AzConnectedMachine { }
        }

        It 'Should not throw and should continue processing remaining machines' {
            { & $scriptPath } | Should -Not -Throw
        }

        It 'Should still create a license for the successful machine' {
            & $scriptPath

            Should -Invoke New-AzConnectedMachineLicenseProfile -Times 1 -Exactly -ParameterFilter {
                $MachineName -eq 'goodServer'
            }
        }

        It 'Should emit a warning for the failed machine' {
            & $scriptPath

            Should -Invoke Write-Warning -ParameterFilter {
                $Message -like "*failServer*"
            }
        }
    }

    Context 'When ResourceIds parameter is provided' {

        BeforeEach {
            $rid = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.HybridCompute/machines/specificServer'
            Mock Get-AzResource {
                [PSCustomObject]@{
                    ResourceId        = $rid
                    Name              = 'specificServer'
                    ResourceGroupName = 'rg1'
                    Location          = 'eastus'
                    Properties        = @{
                        osName = 'Windows Server 2012 R2'
                        osSku  = 'Datacenter'
                        detectedProperties = @{ logicalCoreCount = 32 }
                    }
                }
            }
            Mock Get-ExistingEsuLicenses { @() }
            Mock New-AzConnectedMachineLicense {
                [PSCustomObject]@{ Id = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.HybridCompute/licenses/esu-specificServer' }
            }
            Mock New-AzConnectedMachineLicenseProfile { }
            Mock Update-AzConnectedMachine { }
        }

        It 'Should use Get-AzResource instead of Get-ArcMachinesByTag' {
            & $scriptPath -ResourceIds $rid

            Should -Invoke Get-AzResource -Times 1 -Exactly
            Should -Invoke Get-ArcMachinesByTag -Times 0 -Exactly
        }

        It 'Should create a license for the specified resource' {
            & $scriptPath -ResourceIds $rid

            Should -Invoke New-AzConnectedMachineLicense -Times 1 -Exactly
        }
    }
}
