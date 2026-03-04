using '../main.bicep'

param automationAccountName = 'aa-arc-esu-prod'

param logAnalyticsWorkspaceName = 'law-arc-esu-prod'

param emailReceivers = [
  {
    name: 'OpsTeam'
    emailAddress: 'ops-team@example.com'
  }
]

param tags = {
  environment: 'prod'
  project: 'arc-esu-automation'
}
