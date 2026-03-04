using '../main.bicep'

param automationAccountName = 'aa-arc-esu-dev'

param logAnalyticsWorkspaceName = 'law-arc-esu-dev'

param emailReceivers = [
  {
    name: 'DevTeam'
    emailAddress: 'dev-team@example.com'
  }
]

param tags = {
  environment: 'dev'
  project: 'arc-esu-automation'
}
