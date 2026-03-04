@description('Name of the Automation Account.')
@minLength(6)
@maxLength(50)
param name string

@description('Azure region for the Automation Account.')
param location string

@description('Resource tags.')
param tags object = {}

@description('Resource ID of the Log Analytics workspace for diagnostic settings.')
param logAnalyticsWorkspaceId string

resource automationAccount 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Basic'
    }
  }
}

resource diagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${name}-diag'
  scope: automationAccount
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        category: 'JobLogs'
        enabled: true
      }
      {
        category: 'JobStreams'
        enabled: true
      }
    ]
  }
}

@description('Resource ID of the Automation Account.')
output id string = automationAccount.id

@description('Name of the Automation Account.')
output name string = automationAccount.name

@description('Principal ID of the system-assigned managed identity.')
output principalId string = automationAccount.identity.principalId
