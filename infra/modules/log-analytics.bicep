@description('Name of the Log Analytics workspace.')
@minLength(4)
@maxLength(63)
param name string

@description('Azure region for the workspace.')
param location string

@description('Number of days to retain data.')
@minValue(7)
@maxValue(730)
param retentionInDays int = 30

@description('Resource tags.')
param tags object = {}

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
  }
}

@description('Resource ID of the Log Analytics workspace.')
output id string = workspace.id

@description('Name of the Log Analytics workspace.')
output name string = workspace.name
