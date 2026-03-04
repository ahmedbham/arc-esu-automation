@description('Name of the Action Group.')
@minLength(1)
param name string

@description('Short name for the Action Group (max 12 characters).')
@minLength(1)
@maxLength(12)
param shortName string

@description('List of email receivers for the Action Group.')
param emailReceivers array

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: name
  location: 'global'
  properties: {
    groupShortName: shortName
    enabled: true
    emailReceivers: [
      for receiver in emailReceivers: {
        name: receiver.name
        emailAddress: receiver.emailAddress
        useCommonAlertSchema: true
      }
    ]
  }
}

@description('Resource ID of the Action Group.')
output id string = actionGroup.id
