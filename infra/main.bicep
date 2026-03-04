targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Name of the Automation Account.')
@minLength(6)
@maxLength(50)
param automationAccountName string = 'aa-arc-esu'

@description('Name of the Log Analytics workspace.')
param logAnalyticsWorkspaceName string = 'law-arc-esu'

@description('Email receivers for alert notifications.')
param emailReceivers array

@description('Tags to apply to all resources.')
param tags object = {}

module logAnalyticsWorkspace 'modules/log-analytics.bicep' = {
  name: 'deploy-log-analytics'
  params: {
    name: logAnalyticsWorkspaceName
    location: location
    tags: tags
  }
}

module automationAccount 'modules/automation-account.bicep' = {
  name: 'deploy-automation-account'
  params: {
    name: automationAccountName
    location: location
    tags: tags
    logAnalyticsWorkspaceId: logAnalyticsWorkspace.outputs.id
  }
}

module actionGroup 'modules/action-group.bicep' = {
  name: 'deploy-action-group'
  params: {
    name: 'ag-arc-esu-alerts'
    shortName: 'ArcESUAlert'
    emailReceivers: emailReceivers
  }
}

module monitorAlerts 'modules/monitor-alerts.bicep' = {
  name: 'deploy-monitor-alerts'
  params: {
    automationAccountId: automationAccount.outputs.id
    actionGroupId: actionGroup.outputs.id
    location: location
    logAnalyticsWorkspaceId: logAnalyticsWorkspace.outputs.id
  }
}

@description('Name of the deployed Automation Account.')
output automationAccountName string = automationAccount.outputs.name

@description('Principal ID of the Automation Account managed identity.')
output automationAccountPrincipalId string = automationAccount.outputs.principalId

@description('Name of the deployed Log Analytics workspace.')
output logAnalyticsWorkspaceName string = logAnalyticsWorkspace.outputs.name
