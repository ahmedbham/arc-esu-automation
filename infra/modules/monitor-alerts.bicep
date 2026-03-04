@description('Resource ID of the Automation Account to monitor.')
param automationAccountId string

@description('Resource ID of the Action Group for alert notifications.')
param actionGroupId string

@description('Azure region for the alert rules.')
param location string

@description('Resource ID of the Log Analytics workspace for scheduled query rules.')
param logAnalyticsWorkspaceId string

// ESU Compliance Gap Alert — Scheduled query rule (log alert)
resource complianceGapAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'ESU Compliance Gap Alert'
  location: location
  properties: {
    displayName: 'ESU Compliance Gap Alert'
    description: 'Fires when ESU compliance gaps are detected in Arc-enabled server assessments.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT1H'
    windowSize: 'PT1H'
    scopes: [
      logAnalyticsWorkspaceId
    ]
    criteria: {
      allOf: [
        {
          query: '''
            AzureDiagnostics
            | where ResourceProvider == "MICROSOFT.AUTOMATION"
            | where Category == "JobStreams"
            | where StreamType_s == "Output"
            | where ResultDescription has "ComplianceGap"
            | summarize GapCount = count() by bin(TimeGenerated, 1h)
            | where GapCount > 0
          '''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroupId
      ]
    }
  }
}

// Runbook Failure Alert — Activity log alert
resource runbookFailureAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: 'Runbook Failure Alert'
  location: 'global'
  properties: {
    description: 'Fires when any Automation runbook job fails.'
    enabled: true
    scopes: [
      automationAccountId
    ]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'Administrative'
        }
        {
          field: 'resourceType'
          equals: 'Microsoft.Automation/automationAccounts/jobs'
        }
        {
          field: 'status'
          equals: 'Failed'
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: actionGroupId
        }
      ]
    }
  }
}
