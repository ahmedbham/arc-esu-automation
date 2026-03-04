# Deployment Guide — Arc ESU Automation

This guide walks through deploying the Arc ESU Automation solution from scratch, covering infrastructure provisioning, runbook import, RBAC setup, schedule configuration, and validation.

---

## 1. Prerequisites

Before you begin, ensure the following are in place:

### Tools

| Tool | Purpose |
|---|---|
| **Azure CLI (`az`)** | Deploys Bicep infrastructure. [Install](https://aka.ms/installazurecli) |
| **Az PowerShell modules** | Used by `Import-Runbooks.ps1` and for schedule/RBAC configuration |

Required Az modules:

```powershell
Install-Module -Name Az.Accounts, Az.Automation, Az.ConnectedMachine, Az.Storage, Az.ResourceGraph -Scope CurrentUser -Force
```

### Permissions

- **Owner** or **Contributor + User Access Administrator** on the target Azure subscription (needed to create resources and assign RBAC roles).

### Azure Resources

- **Storage Account** — used by `Import-Runbooks.ps1` to stage the `EsuHelpers` module zip before importing it into the Automation Account. This can be an existing storage account or a new one you create for staging purposes.

### Source Code

```powershell
git clone <repository-url>
cd arc-esu-automation
```

### Authentication

```powershell
# Azure CLI
az login
az account set --subscription "<your-subscription-id>"

# Az PowerShell (needed for runbook import)
Connect-AzAccount
Set-AzContext -SubscriptionId "<your-subscription-id>"
```

---

## 2. Planning

### Resources Deployed

The Bicep templates deploy the following resources into a single resource group:

| Resource | Type | Description |
|---|---|---|
| **Automation Account** | `Microsoft.Automation/automationAccounts` | Hosts runbooks and the managed identity. Uses the Basic SKU with a system-assigned managed identity. |
| **Log Analytics Workspace** | `Microsoft.OperationalInsights/workspaces` | Receives Automation job logs and job streams (30-day retention by default). |
| **Action Group** | `Microsoft.Insights/actionGroups` | Email notification target for alert rules. |
| **ESU Compliance Gap Alert** | `Microsoft.Insights/scheduledQueryRules` | Scheduled query rule (severity 2, hourly) that fires when compliance gaps appear in job output. |
| **Runbook Failure Alert** | `Microsoft.Insights/activityLogAlerts` | Activity log alert that fires when any Automation runbook job fails. |
| **Diagnostic Settings** | `Microsoft.Insights/diagnosticSettings` | Routes Automation Account `JobLogs` and `JobStreams` to Log Analytics. |

### Choosing a Location

The `Deploy-Infrastructure.ps1` script defaults to `eastus`. Override with `-Location`:

```powershell
-Location "westus2"
```

### Customizing Parameter Files

Two parameter files are provided:

| File | Default Resources | Email Recipient |
|---|---|---|
| `infra\parameters\dev.bicepparam` | `aa-arc-esu-dev`, `law-arc-esu-dev` | `dev-team@example.com` |
| `infra\parameters\prod.bicepparam` | `aa-arc-esu-prod`, `law-arc-esu-prod` | `ops-team@example.com` |

**Before deploying**, edit the parameter file for your environment:

```bicep
// infra\parameters\dev.bicepparam
using '../main.bicep'

param automationAccountName = 'aa-arc-esu-dev'
param logAnalyticsWorkspaceName = 'law-arc-esu-dev'

param emailReceivers = [
  {
    name: 'YourTeam'
    emailAddress: 'your-team@yourcompany.com'    // <-- Update this
  }
]

param tags = {
  environment: 'dev'
  project: 'arc-esu-automation'
}
```

---

## 3. Infrastructure Deployment

### Preview Changes (Recommended First Step)

```powershell
.\scripts\Deploy-Infrastructure.ps1 `
    -ResourceGroupName "rg-arc-esu-dev" `
    -Location "eastus" `
    -Environment dev `
    -WhatIf
```

This runs `az deployment group create --what-if` so you can review planned changes without modifying any Azure resources.

### Deploy

```powershell
.\scripts\Deploy-Infrastructure.ps1 `
    -ResourceGroupName "rg-arc-esu-dev" `
    -Location "eastus" `
    -Environment dev
```

The script will:

1. Check that `az` CLI is available.
2. Create the resource group if it doesn't exist.
3. Deploy `infra\main.bicep` using the `dev.bicepparam` parameter file.
4. Output the deployment result as JSON, including the Automation Account name and managed identity principal ID.

**Save the output** — you'll need the `automationAccountPrincipalId` for RBAC assignments in the next step.

---

## 4. Post-Infrastructure Setup — RBAC Roles

The Automation Account uses a **system-assigned managed identity** to interact with Azure resources. You must assign the following roles on every subscription that contains Arc-connected machines.

### Required Roles

| Role | Purpose |
|---|---|
| **Reader** | Allows Resource Graph queries to discover Arc machines |
| **Azure Connected Machine Resource Administrator** | Allows creating and assigning ESU license resources |
| **Tag Contributor** | Allows tagging machines with `ESU:Required` / `ESU:Excluded` |

### Assign Roles

Replace `<principal-id>` with the `automationAccountPrincipalId` from the deployment output and `<subscription-id>` with each target subscription:

```powershell
# Get the principal ID from the deployment output
$principalId = "<principal-id>"
$subscriptionId = "<subscription-id>"

# Reader — for Azure Resource Graph queries
az role assignment create `
    --assignee-object-id $principalId `
    --assignee-principal-type ServicePrincipal `
    --role "Reader" `
    --scope "/subscriptions/$subscriptionId"

# Azure Connected Machine Resource Administrator — for ESU license management
az role assignment create `
    --assignee-object-id $principalId `
    --assignee-principal-type ServicePrincipal `
    --role "Azure Connected Machine Resource Administrator" `
    --scope "/subscriptions/$subscriptionId"

# Tag Contributor — for tagging Arc machines
az role assignment create `
    --assignee-object-id $principalId `
    --assignee-principal-type ServicePrincipal `
    --role "Tag Contributor" `
    --scope "/subscriptions/$subscriptionId"
```

> **Tip:** If your Arc machines span multiple subscriptions, repeat the commands for each subscription. You can also scope to a management group for broader coverage.

---

## 5. Runbook Import

Import and publish all runbooks and the shared `EsuHelpers` module into the Automation Account.

### Pre-requisite

Ensure you have a **Storage Account** accessible from your current session. The script uses it to stage the `EsuHelpers.psm1` module as a zip blob before importing it. The staging blob is automatically cleaned up after import.

### Import

```powershell
.\scripts\Import-Runbooks.ps1 `
    -ResourceGroupName "rg-arc-esu-dev" `
    -AutomationAccountName "aa-arc-esu-dev" `
    -StorageAccountName "stesustaging"
```

Optional: specify a custom container name (default is `automation-modules`):

```powershell
.\scripts\Import-Runbooks.ps1 `
    -ResourceGroupName "rg-arc-esu-dev" `
    -AutomationAccountName "aa-arc-esu-dev" `
    -StorageAccountName "stesustaging" `
    -StorageContainerName "my-custom-container"
```

### What Gets Imported

| Asset | Type | Source |
|---|---|---|
| **Discover-ArcEsuMachines** | PowerShell Runbook | `runbooks\Discover-ArcEsuMachines.ps1` |
| **Apply-EsuLicense** | PowerShell Runbook | `runbooks\Apply-EsuLicense.ps1` |
| **Sync-EsuLicenses** | PowerShell Runbook | `runbooks\Sync-EsuLicenses.ps1` |
| **Report-EsuCompliance** | PowerShell Runbook | `runbooks\Report-EsuCompliance.ps1` |
| **EsuHelpers** | PowerShell Module | `runbooks\common\EsuHelpers.psm1` |

---

## 6. Schedule Configuration

After importing runbooks, create schedules in the Automation Account and link them to each runbook.

### Recommended Schedule

| Runbook | Time (UTC) | Rationale |
|---|---|---|
| **Discover-ArcEsuMachines** | 2:00 AM daily | Discovers new machines first |
| **Apply-EsuLicense** | 3:00 AM daily | Assigns licenses to newly discovered machines |
| **Sync-EsuLicenses** | 4:00 AM daily | Reconciles licenses against current machine state |
| **Report-EsuCompliance** | 5:00 AM daily | Generates compliance report after all changes |

### Create Schedules and Link to Runbooks

```powershell
$rg = "rg-arc-esu-dev"
$aa = "aa-arc-esu-dev"
$startDate = (Get-Date).AddDays(1).Date  # Start tomorrow

# Discover — daily at 2:00 AM UTC
$discoverSchedule = New-AzAutomationSchedule `
    -ResourceGroupName $rg `
    -AutomationAccountName $aa `
    -Name "Daily-Discover-ArcEsuMachines" `
    -StartTime ($startDate.AddHours(2)) `
    -DayInterval 1 `
    -TimeZone "UTC"

Register-AzAutomationScheduledRunbook `
    -ResourceGroupName $rg `
    -AutomationAccountName $aa `
    -RunbookName "Discover-ArcEsuMachines" `
    -ScheduleName "Daily-Discover-ArcEsuMachines"

# Apply — daily at 3:00 AM UTC
$applySchedule = New-AzAutomationSchedule `
    -ResourceGroupName $rg `
    -AutomationAccountName $aa `
    -Name "Daily-Apply-EsuLicense" `
    -StartTime ($startDate.AddHours(3)) `
    -DayInterval 1 `
    -TimeZone "UTC"

Register-AzAutomationScheduledRunbook `
    -ResourceGroupName $rg `
    -AutomationAccountName $aa `
    -RunbookName "Apply-EsuLicense" `
    -ScheduleName "Daily-Apply-EsuLicense"

# Sync — daily at 4:00 AM UTC
$syncSchedule = New-AzAutomationSchedule `
    -ResourceGroupName $rg `
    -AutomationAccountName $aa `
    -Name "Daily-Sync-EsuLicenses" `
    -StartTime ($startDate.AddHours(4)) `
    -DayInterval 1 `
    -TimeZone "UTC"

Register-AzAutomationScheduledRunbook `
    -ResourceGroupName $rg `
    -AutomationAccountName $aa `
    -RunbookName "Sync-EsuLicenses" `
    -ScheduleName "Daily-Sync-EsuLicenses"

# Report — daily at 5:00 AM UTC
$reportSchedule = New-AzAutomationSchedule `
    -ResourceGroupName $rg `
    -AutomationAccountName $aa `
    -Name "Daily-Report-EsuCompliance" `
    -StartTime ($startDate.AddHours(5)) `
    -DayInterval 1 `
    -TimeZone "UTC"

Register-AzAutomationScheduledRunbook `
    -ResourceGroupName $rg `
    -AutomationAccountName $aa `
    -RunbookName "Report-EsuCompliance" `
    -ScheduleName "Daily-Report-EsuCompliance"
```

---

## 7. Validation

After completing the deployment, verify everything is working correctly.

### Check Automation Account

```powershell
# List runbooks — all 4 should be Published
Get-AzAutomationRunbook -ResourceGroupName "rg-arc-esu-dev" -AutomationAccountName "aa-arc-esu-dev" |
    Select-Object Name, State |
    Format-Table -AutoSize
```

Expected output:

```
Name                       State
----                       -----
Apply-EsuLicense           Published
Discover-ArcEsuMachines    Published
Report-EsuCompliance       Published
Sync-EsuLicenses           Published
```

### Verify EsuHelpers Module

```powershell
Get-AzAutomationModule -ResourceGroupName "rg-arc-esu-dev" -AutomationAccountName "aa-arc-esu-dev" -Name "EsuHelpers"
```

The `ProvisioningState` should be `Succeeded`.

### Test-Run the Discovery Runbook

```powershell
$job = Start-AzAutomationRunbook `
    -ResourceGroupName "rg-arc-esu-dev" `
    -AutomationAccountName "aa-arc-esu-dev" `
    -Name "Discover-ArcEsuMachines" `
    -Wait

# Check job status
Get-AzAutomationJob -ResourceGroupName "rg-arc-esu-dev" `
    -AutomationAccountName "aa-arc-esu-dev" `
    -Id $job.JobId |
    Select-Object Status, StartTime, EndTime
```

### Verify Log Analytics Is Receiving Data

After a runbook completes, check that job logs are flowing to the workspace:

```powershell
# In Azure Portal: Log Analytics workspace > Logs
# Run this KQL query:
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION"
| where Category == "JobLogs"
| project TimeGenerated, ResultType, RunbookName_s, JobId_g
| order by TimeGenerated desc
| take 10
```

### Verify Alerts

In the Azure Portal, navigate to:

1. **Monitor > Alerts** — confirm the two alert rules are present and enabled:
   - `ESU Compliance Gap Alert` (scheduled query rule)
   - `Runbook Failure Alert` (activity log alert)
2. **Monitor > Action Groups** — confirm `ag-arc-esu-alerts` exists with the correct email receivers.

---

## 8. Production Deployment

### Differences from Dev

| Aspect | Dev | Prod |
|---|---|---|
| Automation Account | `aa-arc-esu-dev` | `aa-arc-esu-prod` |
| Log Analytics Workspace | `law-arc-esu-dev` | `law-arc-esu-prod` |
| Email Recipients | `dev-team@example.com` | `ops-team@example.com` |
| Environment Tag | `dev` | `prod` |

### Customize `prod.bicepparam`

Before deploying to production, update `infra\parameters\prod.bicepparam`:

```bicep
using '../main.bicep'

param automationAccountName = 'aa-arc-esu-prod'
param logAnalyticsWorkspaceName = 'law-arc-esu-prod'

param emailReceivers = [
  {
    name: 'OpsTeam'
    emailAddress: 'ops-team@yourcompany.com'    // <-- Update with real email
  }
]

param tags = {
  environment: 'prod'
  project: 'arc-esu-automation'
}
```

### Pre-Production Checklist

- [ ] `prod.bicepparam` has correct email recipients
- [ ] Resource group name and location are decided
- [ ] RBAC roles are documented for all target subscriptions
- [ ] Storage account for module staging is available
- [ ] Dev environment has been validated successfully
- [ ] Runbooks have been tested in dev with real Arc machines

### Deploy Production

```powershell
# Preview
.\scripts\Deploy-Infrastructure.ps1 `
    -ResourceGroupName "rg-arc-esu-prod" `
    -Location "eastus" `
    -Environment prod `
    -WhatIf

# Deploy
.\scripts\Deploy-Infrastructure.ps1 `
    -ResourceGroupName "rg-arc-esu-prod" `
    -Location "eastus" `
    -Environment prod

# Import runbooks
.\scripts\Import-Runbooks.ps1 `
    -ResourceGroupName "rg-arc-esu-prod" `
    -AutomationAccountName "aa-arc-esu-prod" `
    -StorageAccountName "stesustagingprod"

# Assign RBAC roles (repeat Section 4 commands with prod principal ID)
# Create schedules (repeat Section 6 commands with prod resource names)
```

---

## 9. Updating / Redeployment

### Updating Runbooks After Code Changes

If you modify runbook scripts locally, re-import them:

```powershell
.\scripts\Import-Runbooks.ps1 `
    -ResourceGroupName "rg-arc-esu-dev" `
    -AutomationAccountName "aa-arc-esu-dev" `
    -StorageAccountName "stesustaging"
```

The script uses `-Force` when importing, so existing runbooks are overwritten and re-published. Schedules are preserved — they remain linked to the runbook by name.

### Updating Infrastructure

Re-run the deployment script to apply infrastructure changes. Bicep deployments are idempotent:

```powershell
.\scripts\Deploy-Infrastructure.ps1 `
    -ResourceGroupName "rg-arc-esu-dev" `
    -Environment dev `
    -WhatIf    # Always preview first

.\scripts\Deploy-Infrastructure.ps1 `
    -ResourceGroupName "rg-arc-esu-dev" `
    -Environment dev
```

### Rollback Procedures

**Runbook rollback:** If a runbook update causes issues, revert the source file to the previous version using Git and re-import:

```powershell
git checkout HEAD~1 -- runbooks/Discover-ArcEsuMachines.ps1

.\scripts\Import-Runbooks.ps1 `
    -ResourceGroupName "rg-arc-esu-dev" `
    -AutomationAccountName "aa-arc-esu-dev" `
    -StorageAccountName "stesustaging"
```

**Infrastructure rollback:** Revert the Bicep files and redeploy:

```powershell
git checkout HEAD~1 -- infra/

.\scripts\Deploy-Infrastructure.ps1 `
    -ResourceGroupName "rg-arc-esu-dev" `
    -Environment dev
```

**Emergency: disable runbooks** without rollback:

```powershell
# Remove all schedules to stop automated execution
Get-AzAutomationSchedule -ResourceGroupName "rg-arc-esu-dev" `
    -AutomationAccountName "aa-arc-esu-dev" |
    Remove-AzAutomationSchedule -Force
```
