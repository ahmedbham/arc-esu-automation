# Azure Arc ESU Automation — Operations Guide

This guide covers day-to-day operations, tag management, common scenarios, monitoring, compliance reporting, manual operations, troubleshooting, and cost considerations for the Azure Arc ESU automation solution.

---

## 1. Day-to-Day Operations

### What Happens Automatically

Four runbooks execute on a scheduled cadence within the Azure Automation Account. The expected daily workflow is:

| Order | Runbook | Purpose |
|-------|---------|---------|
| 1 | `Discover-ArcEsuMachines` | Scans all Arc-connected machines for ESU-eligible OS (Windows Server 2012 / 2012 R2) and tag overrides. Newly eligible machines are tagged `ESU:Required`. |
| 2 | `Apply-EsuLicense` | Creates and assigns ESU license resources to machines tagged `ESU:Required` that don't already have a license. Enables Software Assurance on each machine. |
| 3 | `Sync-EsuLicenses` | Detects decommissioned machines (removed, disconnected, or tagged `ESU:Excluded`) and removes orphaned licenses. Also identifies recommissioned machines needing licenses. |
| 4 | `Report-EsuCompliance` | Compares eligible machines against assigned licenses and outputs a JSON compliance report (Compliant, NonCompliant, Orphaned, ExpiringSoon). |

### Monitoring Runbook Execution in the Azure Portal

1. Navigate to **Automation Account → Jobs**.
2. Filter by runbook name or time range.
3. Click a job to view its **Status** (Completed, Failed, Suspended), **Output**, **Errors**, and **Warnings** streams.

### Checking Job Status and Output

- **Output stream**: Contains the structured summary (e.g., `===== ESU Discovery Summary =====`).
- **Warning stream**: Lists individual machine failures or non-compliant machines.
- **Error stream**: Contains fatal errors (authentication failures, unhandled exceptions). If the error stream contains `ESU_COMPLIANCE_ALERT`, non-compliant machines were detected.
- **Verbose stream**: Enable verbose logging on the runbook schedule to see step-by-step processing details.

---

## 2. Tag Management

The system uses the `ESU` tag on Arc machine resources to control eligibility:

| Tag Value | Behavior |
|-----------|----------|
| `ESU:Required` | Force-includes the machine for ESU licensing, even if its OS is not 2012/R2. |
| `ESU:Excluded` | Force-excludes the machine from ESU licensing, even if its OS is 2012/R2. Sync will remove any existing license. |
| *(no tag)* | Machine is included/excluded based on OS detection (Windows Server 2012 / 2012 R2). |

### Tag a Machine for ESU

```bash
az tag update --resource-id <machine-resource-id> --operation Merge --tags ESU=Required
```

### Exclude a Machine from ESU

```bash
az tag update --resource-id <machine-resource-id> --operation Merge --tags ESU=Excluded
```

### Remove a Tag Override (Return to OS-Based Detection)

```bash
az tag update --resource-id <machine-resource-id> --operation Delete --tags ESU=
```

After removing the tag, the next Discovery run will include or exclude the machine based purely on its OS version.

### Bulk Tagging with Azure CLI / Resource Graph

Query eligible machines with Resource Graph, then loop to tag:

```bash
# Find all Arc machines running Windows Server 2012 that are NOT yet tagged
az graph query -q "
  Resources
  | where type =~ 'Microsoft.HybridCompute/machines'
  | where properties.osName contains '2012' or properties.osSku contains '2012'
  | where isnull(tags.ESU) or tags.ESU != 'Required'
  | project id
" --output tsv | while read id; do
  az tag update --resource-id "$id" --operation Merge --tags ESU=Required
done
```

```bash
# Bulk exclude machines in a specific resource group
az graph query -q "
  Resources
  | where type =~ 'Microsoft.HybridCompute/machines'
  | where resourceGroup =~ 'rg-decommissioned'
  | project id
" --output tsv | while read id; do
  az tag update --resource-id "$id" --operation Merge --tags ESU=Excluded
done
```

---

## 3. Common Scenarios

### Onboarding a New Machine

1. Machine is onboarded to Azure Arc (appears as `Microsoft.HybridCompute/machines`).
2. **Discovery** runbook runs on schedule → detects the machine if its OS contains "2012" or if it's tagged `ESU:Required` → applies the `ESU:Required` tag if not already present.
3. **Apply** runbook runs → creates an ESU license, assigns it to the machine, and enables Software Assurance.

No manual intervention required for 2012/R2 machines.

### Decommissioning a Machine

**Option A — Machine removed from Arc:**

1. Machine is deleted or Arc agent uninstalled.
2. **Sync** runbook detects the license is assigned to a non-existent machine.
3. Sync removes the license assignment and deletes the license resource.

**Option B — Tag as excluded (machine stays in Arc):**

1. Tag the machine: `az tag update --resource-id <id> --operation Merge --tags ESU=Excluded`
2. **Sync** runbook detects the `ESU:Excluded` tag → removes the license assignment and deletes the license resource.

### Recommissioning a Machine

1. Machine is re-onboarded to Azure Arc (or reconnected).
2. **Discovery** runbook detects it as ESU-eligible → tags it `ESU:Required`.
3. **Apply** runbook assigns a new ESU license.

If the machine was previously excluded, remove the exclusion tag first:

```bash
az tag update --resource-id <id> --operation Delete --tags ESU=
```

### Forcing ESU on a Non-2012 Machine

1. Tag the machine: `az tag update --resource-id <id> --operation Merge --tags ESU=Required`
2. **Discovery** runbook force-includes it via `Get-ArcMachinesByTag -TagName 'ESU' -TagValue 'Required'`.
3. **Apply** runbook creates and assigns a license (OS details are read from machine properties).

### Excluding an Eligible Machine

1. Tag the machine: `az tag update --resource-id <id> --operation Merge --tags ESU=Excluded`
2. **Discovery** runbook's `Get-EsuEligibleMachines` function excludes it even though its OS matches.
3. If a license already exists, **Sync** removes it on the next run.

---

## 4. Monitoring & Alerting

### Configured Alerts

Two alert rules are deployed via `infra/modules/monitor-alerts.bicep`:

| Alert | Type | Trigger |
|-------|------|---------|
| **ESU Compliance Gap Alert** | Scheduled query rule (log alert) | Fires hourly when `AzureDiagnostics` job output contains `ComplianceGap`. Severity 2. |
| **Runbook Failure Alert** | Activity log alert | Fires when any Automation Account job enters `Failed` status. |

Both alerts send notifications to the configured Action Group.

### Check Alert Status in Azure Monitor

1. Navigate to **Azure Monitor → Alerts**.
2. Filter by resource group or Automation Account.
3. Review fired alerts, severity, and timestamps.

### Modify Alert Recipients

1. Navigate to **Azure Monitor → Action Groups**.
2. Select the action group referenced by the alerts.
3. Edit email/SMS/webhook/ITSM receivers as needed.

### Temporarily Suppress Alerts

**Action rule (alert processing rule):**

1. Navigate to **Azure Monitor → Alert processing rules → Create**.
2. Set scope to the Automation Account or resource group.
3. Set schedule (e.g., suppress for a maintenance window).
4. Action: **Suppress notifications**.

**Maintenance window approach:**

Disable the alert rules directly:

1. Navigate to **Azure Monitor → Alerts → Alert rules**.
2. Select the rule → **Disable**.
3. Re-enable after maintenance.

### Check Log Analytics for Job Logs

Automation Account diagnostic logs flow to Log Analytics. Sample KQL queries:

```kql
// All runbook job completions in the last 24 hours
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION"
| where Category == "JobLogs"
| where TimeGenerated > ago(24h)
| project TimeGenerated, RunbookName_s, ResultType, JobId_g
| order by TimeGenerated desc
```

```kql
// Failed runbook jobs in the last 7 days
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION"
| where Category == "JobLogs"
| where ResultType == "Failed"
| where TimeGenerated > ago(7d)
| project TimeGenerated, RunbookName_s, JobId_g
| order by TimeGenerated desc
```

```kql
// Job output streams (discovery/apply/sync summaries)
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION"
| where Category == "JobStreams"
| where StreamType_s == "Output"
| where TimeGenerated > ago(24h)
| project TimeGenerated, RunbookName_s, ResultDescription
| order by TimeGenerated desc
```

---

## 5. Compliance Reporting

### Understanding the Compliance Report JSON Output

The `Report-EsuCompliance` runbook outputs a JSON object with the following structure:

| Field | Description |
|-------|-------------|
| `ReportTimestamp` | ISO 8601 timestamp of the report run. |
| `TotalEligibleMachines` | Count of all ESU-eligible machines (OS-based + tag overrides). |
| `CompliantCount` | Machines with a valid ESU license assigned. |
| `CompliancePercentage` | `CompliantCount / TotalEligibleMachines × 100`, rounded to 2 decimals. |
| `NonCompliantCount` | Eligible machines without an ESU license. |
| `OrphanedLicenseCount` | Licenses assigned to machines not in the eligible set. |
| `ExpiringSoonCount` | Licenses expiring within 30 days. |
| `Machines` | Array of per-machine details (Name, ResourceGroup, SubscriptionId, ComplianceStatus, AssignedLicense). |
| `OrphanedLicenses` | Array of orphaned license details (LicenseId, LicenseName, ResourceGroup). |
| `ExpiringSoonLicenses` | Array of expiring license details (LicenseId, LicenseName, ExpirationDate, DaysRemaining). |

### Key Metrics

- **Total eligible**: Machines detected by OS or force-included by `ESU:Required` tag (minus `ESU:Excluded`).
- **Compliant %**: Target is 100%. Any value below indicates machines needing license assignment.
- **Non-compliant count**: Machines that should have a license but don't. Investigate Apply runbook output.
- **Orphaned licenses**: Licenses consuming cost for machines no longer eligible. Sync runbook should clean these up.

### Query Historical Compliance Data in Log Analytics

```kql
// Parse compliance reports from job output over the last 30 days
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION"
| where Category == "JobStreams"
| where StreamType_s == "Output"
| where RunbookName_s == "Report-EsuCompliance"
| where TimeGenerated > ago(30d)
| extend Report = parse_json(ResultDescription)
| project
    TimeGenerated,
    TotalEligible = toint(Report.TotalEligibleMachines),
    Compliant = toint(Report.CompliantCount),
    CompliancePct = todouble(Report.CompliancePercentage),
    NonCompliant = toint(Report.NonCompliantCount),
    Orphaned = toint(Report.OrphanedLicenseCount)
| order by TimeGenerated desc
```

```kql
// Compliance trend chart (for Azure Dashboard / Workbook)
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION"
| where Category == "JobStreams"
| where StreamType_s == "Output"
| where RunbookName_s == "Report-EsuCompliance"
| where TimeGenerated > ago(90d)
| extend Report = parse_json(ResultDescription)
| project
    TimeGenerated,
    CompliancePct = todouble(Report.CompliancePercentage),
    NonCompliant = toint(Report.NonCompliantCount),
    Orphaned = toint(Report.OrphanedLicenseCount)
| render timechart
```

---

## 6. Manual Operations

### Running a Runbook On-Demand from the Portal

1. Navigate to **Automation Account → Runbooks**.
2. Select the runbook (e.g., `Discover-ArcEsuMachines`).
3. Click **Start**.
4. Optionally fill in parameters (`SubscriptionId`, `DryRun`, etc.).
5. Click **OK** and monitor the job.

### Running a Runbook via PowerShell

```powershell
# Discover eligible machines
Start-AzAutomationRunbook -Name "Discover-ArcEsuMachines" `
    -ResourceGroupName "rg-arc-esu" `
    -AutomationAccountName "aa-arc-esu"

# Apply licenses
Start-AzAutomationRunbook -Name "Apply-EsuLicense" `
    -ResourceGroupName "rg-arc-esu" `
    -AutomationAccountName "aa-arc-esu"

# Sync licenses
Start-AzAutomationRunbook -Name "Sync-EsuLicenses" `
    -ResourceGroupName "rg-arc-esu" `
    -AutomationAccountName "aa-arc-esu"

# Generate compliance report
Start-AzAutomationRunbook -Name "Report-EsuCompliance" `
    -ResourceGroupName "rg-arc-esu" `
    -AutomationAccountName "aa-arc-esu"
```

### Running Sync in DryRun Mode First

Always run Sync in DryRun mode before executing in production to preview changes:

```powershell
Start-AzAutomationRunbook -Name "Sync-EsuLicenses" `
    -ResourceGroupName "rg-arc-esu" `
    -AutomationAccountName "aa-arc-esu" `
    -Parameters @{ DryRun = $true }
```

DryRun output is prefixed with `[DRY RUN]` and reports planned removals without executing them.

### Targeting Specific Subscriptions

Pass the `SubscriptionId` parameter to scope any runbook to specific subscriptions:

```powershell
Start-AzAutomationRunbook -Name "Discover-ArcEsuMachines" `
    -ResourceGroupName "rg-arc-esu" `
    -AutomationAccountName "aa-arc-esu" `
    -Parameters @{ SubscriptionId = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" }
```

Multiple subscriptions can be passed as a comma-separated string when using the portal, or as an array via PowerShell.

---

## 7. Troubleshooting

### Runbook Fails to Authenticate

**Symptoms:** Job fails with `Failed to connect using Managed Identity`.

**Resolution:**

1. Verify the Automation Account has a **System-assigned Managed Identity** enabled:
   - Automation Account → Identity → System assigned → Status = **On**.
2. Verify the Managed Identity has the required RBAC roles:
   - `Reader` on target subscriptions (for Resource Graph queries).
   - `Tag Contributor` on target subscriptions (for tagging machines).
   - `Connected Machine Resource Administrator` on target subscriptions (for license operations).
3. Check that required Az modules are imported into the Automation Account:
   - `Az.Accounts`, `Az.ResourceGraph`, `Az.Resources`, `Az.ConnectedMachine`.

### Discovery Finds No Machines

**Symptoms:** Discovery summary shows `ESU-eligible machines found: 0`.

**Resolution:**

1. **Check subscription scope**: If `SubscriptionId` is specified, ensure the target subscriptions are correct. If omitted, the Managed Identity must have Reader access to the subscriptions containing Arc machines.
2. **Verify Arc agent connectivity**: In the Azure Portal, navigate to **Azure Arc → Servers** and confirm machines show status `Connected`.
3. **Test the Resource Graph query manually**: Open **Azure Resource Graph Explorer** in the portal and run:
   ```kql
   Resources
   | where type =~ 'Microsoft.HybridCompute/machines'
   | where properties.osName contains '2012' or properties.osSku contains '2012'
   | project id, name, properties.osName, properties.osSku
   ```
4. **Check for `ESU:Excluded` tags**: Machines tagged `ESU:Excluded` are filtered out even if their OS matches.

### License Creation Fails

**Symptoms:** Apply runbook output shows `Failed` entries with errors.

**Resolution:**

1. **Check RBAC**: The Managed Identity needs `Connected Machine Resource Administrator` role on the target subscription/resource group.
2. **Verify OS version**: The machine's `properties.osName` or `properties.osSku` must contain "2012". Non-2012 machines need the `ESU:Required` tag.
3. **Check license quota**: Azure subscriptions have limits on ESU license resources. Contact Azure support if you hit quota limits.
4. **Check Az.ConnectedMachine module**: Ensure the `Az.ConnectedMachine` module is imported and up to date in the Automation Account.
5. **Minimum core count**: The runbook enforces a minimum of 8 cores per license. Verify the machine's `detectedProperties.logicalCoreCount` is populated.

### Compliance Report Shows False Non-Compliance

**Symptoms:** Report shows machines as `NonCompliant` even though licenses were applied.

**Resolution:**

1. **Check Apply runbook output**: Verify the Apply job completed successfully and the machine appears under "Newly Licensed Machines".
2. **Resource Graph propagation delay**: Resource Graph data can take several minutes to propagate. Re-run the compliance report after waiting 5–10 minutes.
3. **License assignment mismatch**: Verify the license's `assignedMachineResourceId` matches the machine's resource ID (case-insensitive comparison).

### Alerts Not Firing

**Symptoms:** Runbook failures or compliance gaps occur but no alert notifications are received.

**Resolution:**

1. **Check diagnostic settings**: Ensure the Automation Account has diagnostic settings configured to send `JobLogs` and `JobStreams` to the Log Analytics workspace referenced by the alert rules.
   - Automation Account → Diagnostic settings → Verify a setting exists that sends to the correct workspace.
2. **Verify Action Group**: Navigate to **Azure Monitor → Action Groups** and confirm the email/SMS/webhook receivers are correct and not suppressed.
3. **Check alert rule status**: Navigate to **Azure Monitor → Alerts → Alert rules** and verify both rules show **Enabled**.
4. **Test the Action Group**: Use the **Test** button on the Action Group to send a test notification.
5. **Check the compliance gap query**: The alert fires on `ResultDescription has "ComplianceGap"`. Verify the compliance report runbook outputs this keyword when gaps are detected.

---

## 8. Cost Considerations

### ESU License Costs Per Machine

- Each ESU license incurs a monthly cost based on the edition (Standard or Datacenter) and the number of cores (minimum 8 physical cores per license).
- Datacenter edition licenses cost more than Standard edition.
- Costs are billed per machine per month as long as the license resource exists and is in `Activated` state.

### How Decommission Sync Helps Reduce Costs

The `Sync-EsuLicenses` runbook automatically detects and removes licenses for:

- **Machines removed from Arc**: License is orphaned and consuming cost with no benefit.
- **Disconnected/expired machines**: Machines that are no longer connected stop receiving updates but still incur license cost.
- **Excluded machines**: Machines tagged `ESU:Excluded` should not have a license.

Running Sync on a regular schedule ensures you are not paying for licenses on machines that no longer need them. Use **DryRun mode** first to preview what would be removed.

### Monitoring Automation Account Run Costs

- Azure Automation provides 500 minutes of free job runtime per month.
- Beyond the free tier, jobs are billed per minute.
- Monitor usage in **Automation Account → Usage + quotas** or via **Azure Cost Management**.
- Each runbook run typically completes in under a minute for small environments. Larger environments with hundreds of machines may take longer.
- Optimize by scoping runbooks to specific subscriptions (`SubscriptionId` parameter) to reduce Resource Graph query volume.
