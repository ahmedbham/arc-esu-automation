# Runbook Reference

This document is the comprehensive reference for all Azure Automation runbooks in the Arc ESU Automation project. It covers the shared helper module, each runbook's purpose, parameters, behavior, and troubleshooting guidance.

All runbooks automate the lifecycle of Extended Security Updates (ESU) for Azure Arc-connected machines running Windows Server 2012 and 2012 R2. They share a common helper module (`EsuHelpers.psm1`) and authenticate via Automation Account Managed Identity.

---

## Shared Helper Module (`EsuHelpers.psm1`)

**Location:** `runbooks/common/EsuHelpers.psm1`

**Required Az Modules:** `Az.Accounts`, `Az.ResourceGraph`, `Az.Resources`

This module provides common functions used by all four runbooks. It handles authentication, Azure Resource Graph queries, eligibility logic, and tagging.

---

### `Connect-AutomationAccount`

**Synopsis:** Authenticates to Azure using the Automation Account's Managed Identity.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| *(none)* | — | — | This function takes no parameters. |

**Return Type:** `void` — no return value on success.

**Example Usage:**

```powershell
Connect-AutomationAccount
```

**Error Handling:** Throws a terminating error with the message `"Failed to connect using Managed Identity: <details>"` if `Connect-AzAccount -Identity` fails. Callers should wrap in a `try/catch` block.

---

### `Get-ArcMachinesByTag`

**Synopsis:** Queries Azure Resource Graph for Arc machines filtered by a specific tag name and value.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `TagName` | `string` | Yes | — | The tag name to filter on (e.g., `ESU`). |
| `TagValue` | `string` | Yes | — | The tag value to filter on (e.g., `Required`). |
| `SubscriptionId` | `string[]` | No | All accessible | Array of subscription IDs to scope the query. |

**Return Type:** `ArrayList` of Resource Graph result objects. Each object contains: `id`, `name`, `resourceGroup`, `subscriptionId`, `location`, `tags`, `properties`.

**Example Usage:**

```powershell
Get-ArcMachinesByTag -TagName 'ESU' -TagValue 'Required'

Get-ArcMachinesByTag -TagName 'Environment' -TagValue 'Production' -SubscriptionId 'sub-id-1','sub-id-2'
```

**Error Handling:** Throws `"Failed to query Arc machines by tag (<TagName>=<TagValue>): <details>"`. Supports pagination via `SkipToken` internally.

---

### `Get-ArcMachinesByOs`

**Synopsis:** Queries Azure Resource Graph for Arc machines running ESU-eligible OS versions (Windows Server 2012 / 2012 R2).

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `SubscriptionId` | `string[]` | No | All accessible | Array of subscription IDs to scope the query. |

**Return Type:** `ArrayList` of Resource Graph result objects with fields: `id`, `name`, `resourceGroup`, `subscriptionId`, `location`, `tags`, `properties`.

**Example Usage:**

```powershell
Get-ArcMachinesByOs

Get-ArcMachinesByOs -SubscriptionId 'sub-id-1'
```

**Error Handling:** Throws `"Failed to query Arc machines by OS: <details>"`. Filters on `properties.osName` or `properties.osSku` containing `"2012"`.

---

### `Get-EsuEligibleMachines`

**Synopsis:** Returns the combined, de-duplicated set of ESU-eligible Arc machines using OS detection and tag overrides.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `SubscriptionId` | `string[]` | No | All accessible | Array of subscription IDs to scope the query. |

**Return Type:** `PSObject[]` — array of eligible machine objects (same structure as Resource Graph results).

**Behavior (4-step process):**

1. **OS detection** — calls `Get-ArcMachinesByOs` to find Windows Server 2012/R2 machines.
2. **Force-include** — calls `Get-ArcMachinesByTag -TagName 'ESU' -TagValue 'Required'` to include machines tagged for ESU regardless of OS.
3. **Force-exclude** — calls `Get-ArcMachinesByTag -TagName 'ESU' -TagValue 'Excluded'` to remove machines opted out of ESU.
4. **De-duplicate** — merges results by resource ID (case-insensitive), applying exclusions.

**Example Usage:**

```powershell
Get-EsuEligibleMachines

$machines = Get-EsuEligibleMachines -SubscriptionId 'sub-id-1' -Verbose
```

**Error Handling:** Throws `"Failed to determine ESU-eligible machines: <details>"`.

---

### `Get-ExistingEsuLicenses`

**Synopsis:** Queries Azure Resource Graph for existing `Microsoft.HybridCompute/licenses` resources.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `SubscriptionId` | `string[]` | No | All accessible | Array of subscription IDs to scope the query. |

**Return Type:** `ArrayList` of license Resource Graph result objects with fields: `id`, `name`, `resourceGroup`, `subscriptionId`, `location`, `tags`, `properties`.

**Example Usage:**

```powershell
Get-ExistingEsuLicenses

Get-ExistingEsuLicenses -SubscriptionId 'sub-id-1','sub-id-2'
```

**Error Handling:** Throws `"Failed to query existing ESU licenses: <details>"`. Supports pagination via `SkipToken` internally.

---

### `Set-MachineEsuTag`

**Synopsis:** Applies an ESU-related tag to an Arc machine using a merge operation.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `ResourceId` | `string` | Yes | — | Full Azure resource ID of the Arc machine. |
| `TagName` | `string` | No | `ESU` | The tag name to set. |
| `TagValue` | `string` | No | `Required` | The tag value to set. |

**Return Type:** `void` — no return value on success.

**Example Usage:**

```powershell
Set-MachineEsuTag -ResourceId '/subscriptions/.../machines/myServer'

Set-MachineEsuTag -ResourceId '/subscriptions/.../machines/myServer' -TagName 'ESU' -TagValue 'Excluded'
```

**Error Handling:** Throws `"Failed to set tag <TagName>=<TagValue> on resource <ResourceId>: <details>"`. Uses `Update-AzTag` with `-Operation Merge` so existing tags are preserved.

---

## Discover-ArcEsuMachines

**File:** `runbooks/Discover-ArcEsuMachines.ps1`

### Purpose

Scans Azure Arc-connected machines to identify those eligible for ESU (Windows Server 2012/2012 R2) using OS detection and tag overrides. Automatically tags newly discovered eligible machines with `ESU:Required`.

### Parameters

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `SubscriptionId` | `string[]` | No | All accessible subscriptions | Array of subscription IDs to scope the discovery. |

### Prerequisites

- Automation Account with a system-assigned Managed Identity.
- Managed Identity has `Reader` and `Tag Contributor` roles on target subscriptions.
- Az modules (`Az.Accounts`, `Az.ResourceGraph`, `Az.Resources`) imported into the Automation Account.
- `EsuHelpers.psm1` present in the `common` subfolder relative to the runbook.

### Behavior

1. Imports the `EsuHelpers.psm1` helper module.
2. Authenticates using `Connect-AutomationAccount` (Managed Identity).
3. Calls `Get-EsuEligibleMachines` to discover all ESU-eligible Arc machines (OS-based + tag overrides).
4. Iterates through each eligible machine:
   - If the machine does **not** already have the `ESU:Required` tag → applies the tag via `Set-MachineEsuTag`.
   - If the machine already has `ESU:Required` → skips it.
5. Builds and outputs a structured summary to the job output stream.

### Output

Plain-text summary written via `Write-Output`:

```
===== ESU Discovery Summary =====
ESU-eligible machines found : <count>
Newly tagged               : <count>
Already tagged             : <count>
=================================

Machine Details:
Name          ResourceGroup  Subscription  EsuTagStatus
----          -------------  ------------  ------------
server01      rg-prod        sub-id-1      Newly Tagged
server02      rg-prod        sub-id-1      Already Tagged
```

### Scheduling

**Recommended:** Daily (e.g., 06:00 UTC). New Arc machines onboarded throughout the day will be picked up and tagged on the next run.

### Error Handling

- **Top-level `try/catch`:** If any unrecoverable error occurs (authentication failure, module import failure), the runbook writes to `Write-Error` and re-throws, failing the Azure Automation job.
- **Per-machine isolation:** Tagging failures for individual machines do not stop the overall runbook (the `Set-MachineEsuTag` function throws, but the loop continues for other machines only if wrapped accordingly — currently the loop does not isolate per-machine errors, so a single tagging failure will propagate to the top-level catch).

### Examples

**Running from Azure Portal:**

1. Navigate to your Automation Account → **Runbooks** → **Discover-ArcEsuMachines**.
2. Click **Start**.
3. Optionally provide `SubscriptionId` values.
4. Review the output in the **Output** tab of the job.

**Running via PowerShell:**

```powershell
# Run across all accessible subscriptions
Start-AzAutomationRunbook -AutomationAccountName 'my-automation' `
    -ResourceGroupName 'rg-automation' `
    -Name 'Discover-ArcEsuMachines'

# Scope to specific subscriptions
Start-AzAutomationRunbook -AutomationAccountName 'my-automation' `
    -ResourceGroupName 'rg-automation' `
    -Name 'Discover-ArcEsuMachines' `
    -Parameters @{ SubscriptionId = 'sub-id-1','sub-id-2' }
```

### Troubleshooting

| Issue | Cause | Solution |
|-------|-------|----------|
| `Failed to connect using Managed Identity` | Managed Identity not enabled or missing role assignments. | Ensure system-assigned MI is enabled and has `Reader` on target subscriptions. |
| `Failed to query Arc machines by OS` | Az.ResourceGraph module missing or insufficient permissions. | Import `Az.ResourceGraph` into the Automation Account; verify MI has `Reader` role. |
| `Failed to set tag` on a machine | MI lacks `Tag Contributor` role. | Assign `Tag Contributor` to the MI on the target subscription or resource group. |
| Zero machines found | No Arc machines with WS2012/R2 OS, or the `ESU:Excluded` tag is applied to all. | Verify Arc machines exist and check tag values in the Azure Portal. |

---

## Apply-EsuLicense

**File:** `runbooks/Apply-EsuLicense.ps1`

### Purpose

Creates and assigns ESU licenses to eligible Azure Arc-connected machines. Machines that already have an ESU license assignment are skipped. Supports both automatic discovery (via `ESU:Required` tag) and explicit resource ID targeting.

### Parameters

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `SubscriptionId` | `string[]` | No | All accessible subscriptions | Array of subscription IDs to scope the machine and license queries. |
| `ResourceIds` | `string[]` | No | — | Explicit list of Arc machine resource IDs to process. Overrides tag-based discovery. |

### Prerequisites

- Automation Account with a system-assigned Managed Identity.
- Managed Identity has `Contributor` role on target subscriptions (required to create license resources and update machines).
- Az modules (`Az.Accounts`, `Az.ResourceGraph`, `Az.Resources`, `Az.ConnectedMachine`) imported.
- `EsuHelpers.psm1` present in the `common` subfolder.
- Machines should already be tagged `ESU:Required` (typically via `Discover-ArcEsuMachines`).

### Behavior

1. Imports the `EsuHelpers.psm1` helper module.
2. Authenticates using `Connect-AutomationAccount`.
3. Determines target machines:
   - If `ResourceIds` is provided → resolves each resource ID via `Get-AzResource`.
   - Otherwise → discovers machines tagged `ESU:Required` via `Get-ArcMachinesByTag`.
4. Retrieves existing ESU licenses via `Get-ExistingEsuLicenses` and builds a lookup of already-licensed machine IDs.
5. For each target machine:
   - **Skip** if the machine already has a license assigned.
   - **Detect OS edition**: `Datacenter` if `osSku` matches "Datacenter", otherwise `Standard`.
   - **Determine core count**: uses `detectedProperties.logicalCoreCount`, minimum 8 cores.
   - **Determine target OS**: `WindowsServer2012R2` if OS name/SKU contains "2012 R2", otherwise `WindowsServer2012`.
   - **Create license**: calls `New-AzConnectedMachineLicense` with name `esu-<machineName>`.
   - **Assign license**: calls `New-AzConnectedMachineLicenseProfile` to link the license to the machine.
   - **Enable Software Assurance**: calls `Update-AzConnectedMachine` with `-LicenseProfileSoftwareAssuranceCustomer $true`.
6. Outputs a structured summary.

### Output

Plain-text summary written via `Write-Output`:

```
===== ESU License Application Summary =====
Total machines processed    : <count>
Licenses created            : <count>
Already licensed (skipped)  : <count>
Failures                    : <count>
============================================

Newly Licensed Machines:
Name      ResourceGroup  LicenseName      Edition     Cores
----      -------------  -----------      -------     -----
server01  rg-prod        esu-server01     Standard    16

Skipped Machines (Already Licensed):
Name      ResourceGroup  Reason
----      -------------  ------
server02  rg-prod        Existing license found

Failed Machines:
Name      ResourceGroup  Error
----      -------------  -----
server03  rg-dev         <error message>
```

### Scheduling

**Recommended:** Daily, scheduled to run **after** `Discover-ArcEsuMachines` (e.g., 07:00 UTC). Can also be run on-demand when new machines need immediate licensing.

### Error Handling

- **Per-machine isolation:** Each machine is processed in its own `try/catch` block inside the loop. A failure on one machine (e.g., license creation error) is logged via `Write-Warning` and recorded in the `failed` collection, but processing continues for remaining machines.
- **Top-level `try/catch`:** Catches unrecoverable errors (authentication failure, module import) and fails the entire job.
- **Skipped machines:** Machines with existing licenses are logged as `AlreadyLicensed` and skipped without error.

### Examples

**Running from Azure Portal:**

1. Navigate to your Automation Account → **Runbooks** → **Apply-EsuLicense**.
2. Click **Start**.
3. Optionally provide `SubscriptionId` or `ResourceIds` values.
4. Review the output in the **Output** tab.

**Running via PowerShell:**

```powershell
# Auto-discover machines tagged ESU:Required
Start-AzAutomationRunbook -AutomationAccountName 'my-automation' `
    -ResourceGroupName 'rg-automation' `
    -Name 'Apply-EsuLicense'

# Target specific machines
Start-AzAutomationRunbook -AutomationAccountName 'my-automation' `
    -ResourceGroupName 'rg-automation' `
    -Name 'Apply-EsuLicense' `
    -Parameters @{
        ResourceIds = '/subscriptions/sub-id-1/resourceGroups/rg-prod/providers/Microsoft.HybridCompute/machines/server01',
                      '/subscriptions/sub-id-1/resourceGroups/rg-prod/providers/Microsoft.HybridCompute/machines/server02'
    }

# Scope to specific subscriptions
Start-AzAutomationRunbook -AutomationAccountName 'my-automation' `
    -ResourceGroupName 'rg-automation' `
    -Name 'Apply-EsuLicense' `
    -Parameters @{ SubscriptionId = 'sub-id-1' }
```

### Troubleshooting

| Issue | Cause | Solution |
|-------|-------|----------|
| `No target machines found` | No machines tagged `ESU:Required`, or `ResourceIds` are invalid. | Run `Discover-ArcEsuMachines` first, or verify the resource IDs. |
| License creation fails with permission error | MI lacks `Contributor` role. | Assign `Contributor` to the MI on the target subscription. |
| `Could not retrieve resource` warning | The resource ID provided in `ResourceIds` doesn't exist or MI can't access it. | Verify the resource ID and MI permissions. |
| License created but profile assignment fails | `Az.ConnectedMachine` module missing or API error. | Ensure `Az.ConnectedMachine` is imported; check Azure service health. |
| Core count defaults to 8 | `detectedProperties.logicalCoreCount` is not populated on the Arc machine. | Ensure the Arc agent is up-to-date and reporting hardware properties. |

---

## Sync-EsuLicenses

**File:** `runbooks/Sync-EsuLicenses.ps1`

### Purpose

Reconciles ESU license assignments with current Arc machine state. Detects decommissioned machines (removed, disconnected, or excluded) and cleans up their licenses. Identifies recommissioned machines that need new license assignments.

### Parameters

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `SubscriptionId` | `string[]` | No | All accessible subscriptions | Array of subscription IDs to scope the sync. |
| `DryRun` | `switch` | No | `$false` | If set, reports planned changes without executing them. Output is prefixed with `[DRY RUN]`. |

### Prerequisites

- Automation Account with a system-assigned Managed Identity.
- Managed Identity has `Contributor` role on target subscriptions (required to remove license resources).
- Az modules (`Az.Accounts`, `Az.ResourceGraph`, `Az.Resources`, `Az.ConnectedMachine`) imported.
- `EsuHelpers.psm1` present in the `common` subfolder.
- Discovery and Apply runbooks should have been run at least once prior.

### Behavior

1. Imports the `EsuHelpers.psm1` helper module.
2. Authenticates using `Connect-AutomationAccount`.
3. Retrieves current ESU-eligible machines via `Get-EsuEligibleMachines`.
4. Retrieves existing ESU licenses via `Get-ExistingEsuLicenses`.
5. **Decommission Detection** — for each license with an assigned machine:
   - Machine no longer exists in Arc or is excluded by eligibility logic → mark for removal.
   - Machine status is not `Connected` (e.g., `Disconnected`, `Expired`) → mark for removal.
   - Machine tagged `ESU:Excluded` → mark for removal.
   - Unless `DryRun` is set, removes the license assignment (`Remove-AzConnectedMachineLicenseProfile`) and then the license resource (`Remove-AzConnectedMachineLicense`).
6. **Recommission Detection** — for each eligible machine:
   - Must be `Connected`, tagged `ESU:Required`, and without a license assignment.
   - These machines are listed in the output for the `Apply-EsuLicense` runbook to handle.
7. Outputs a structured change report.

### Output

Plain-text summary written via `Write-Output`:

```
===== ESU License Sync Summary =====
Licenses removed (decommissioned) : <count>
Removal errors                    : <count>
Machines needing licenses         : <count>
====================================

Decommissioned Licenses:
License        Machine     Reason
-------        -------     ------
esu-server03   server03    Machine status is 'Disconnected' (not Connected)

Machines Needing License Assignment (for Apply-EsuLicense runbook):
Name      ResourceGroup  Subscription  ResourceId
----      -------------  ------------  ----------
server05  rg-prod        sub-id-1      /subscriptions/.../machines/server05
```

When `DryRun` is set, all output lines are prefixed with `[DRY RUN]` and no changes are made.

### Scheduling

**Recommended:** Daily, scheduled to run **after** `Apply-EsuLicense` (e.g., 08:00 UTC). The sync runbook acts as a reconciliation step to clean up stale licenses and flag machines needing attention.

### Error Handling

- **Per-license isolation:** Each license removal is wrapped in its own `try/catch`. Failures are recorded in `removalErrors` and reported in the summary, but processing continues.
- **Top-level `try/catch`:** Catches unrecoverable errors and fails the entire job.
- **DryRun safety:** When `DryRun` is set, no Azure resources are modified — only the report is generated.

### Examples

**Running from Azure Portal:**

1. Navigate to your Automation Account → **Runbooks** → **Sync-EsuLicenses**.
2. Click **Start**.
3. Optionally check `DryRun` to preview changes first.
4. Review the output in the **Output** tab.

**Running via PowerShell:**

```powershell
# Full sync across all subscriptions
Start-AzAutomationRunbook -AutomationAccountName 'my-automation' `
    -ResourceGroupName 'rg-automation' `
    -Name 'Sync-EsuLicenses'

# Dry run — preview changes without applying
Start-AzAutomationRunbook -AutomationAccountName 'my-automation' `
    -ResourceGroupName 'rg-automation' `
    -Name 'Sync-EsuLicenses' `
    -Parameters @{ DryRun = $true }

# Scope to a specific subscription
Start-AzAutomationRunbook -AutomationAccountName 'my-automation' `
    -ResourceGroupName 'rg-automation' `
    -Name 'Sync-EsuLicenses' `
    -Parameters @{ SubscriptionId = 'sub-id-1'; DryRun = $true }
```

### Troubleshooting

| Issue | Cause | Solution |
|-------|-------|----------|
| Licenses flagged for removal when machines are temporarily disconnected | Machine status is `Disconnected` during maintenance windows. | Schedule the sync runbook outside maintenance windows, or review `DryRun` output first. |
| Removal errors | MI lacks permissions to delete license resources. | Assign `Contributor` role to the MI on the target subscription. |
| Machines show as needing licenses but were intentionally unlicensed | Machine is `Connected` and tagged `ESU:Required` but hasn't been licensed yet. | Run `Apply-EsuLicense` to assign licenses, or tag the machine `ESU:Excluded` if it shouldn't be licensed. |
| `[DRY RUN]` prefix appears unexpectedly | The `DryRun` switch was passed. | Remove the `-DryRun` parameter to execute actual changes. |

---

## Report-EsuCompliance

**File:** `runbooks/Report-EsuCompliance.ps1`

### Purpose

Generates a comprehensive ESU compliance report comparing eligible Arc machines against existing ESU license assignments. Outputs structured JSON suitable for Azure Monitor custom log ingestion. Emits warnings and an error marker for non-compliant machines.

### Parameters

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `SubscriptionId` | `string[]` | No | All accessible subscriptions | Array of subscription IDs to scope the report. |

### Prerequisites

- Automation Account with a system-assigned Managed Identity.
- Managed Identity has `Reader` role on target subscriptions.
- Az modules (`Az.Accounts`, `Az.ResourceGraph`, `Az.Resources`) imported.
- `EsuHelpers.psm1` present in the `common` subfolder.
- Discovery, Apply, and Sync runbooks should have been run prior for accurate compliance data.

### Behavior

1. Imports the `EsuHelpers.psm1` helper module.
2. Authenticates using `Connect-AutomationAccount`.
3. Retrieves ESU-eligible machines via `Get-EsuEligibleMachines`.
4. Retrieves existing ESU licenses via `Get-ExistingEsuLicenses`.
5. **Per-machine compliance analysis:**
   - **Compliant:** Eligible machine has a license assigned (found in the license lookup).
   - **NonCompliant:** Eligible machine without a license assignment.
6. **Orphaned license detection:** Licenses assigned to machines not in the eligible set.
7. **Expiration detection:** Licenses with `endDateTime` within 30 days of the current date are flagged as `ExpiringSoon`.
8. Calculates aggregate metrics (compliance percentage, counts).
9. Outputs the full report as JSON via `Write-Output`.
10. For non-compliant machines: emits `Write-Warning` per machine and a `Write-Error` with the `ESU_COMPLIANCE_ALERT` marker.

### Output

JSON object written via `Write-Output` (formatted for Azure Monitor ingestion):

```json
{
  "ReportTimestamp": "2024-01-15T08:30:00.0000000+00:00",
  "TotalEligibleMachines": 10,
  "CompliantCount": 8,
  "CompliancePercentage": 80.0,
  "NonCompliantCount": 2,
  "OrphanedLicenseCount": 1,
  "ExpiringSoonCount": 0,
  "Machines": [
    {
      "Name": "server01",
      "ResourceGroup": "rg-prod",
      "SubscriptionId": "sub-id-1",
      "ComplianceStatus": "Compliant",
      "AssignedLicense": "/subscriptions/.../licenses/esu-server01"
    },
    {
      "Name": "server02",
      "ResourceGroup": "rg-prod",
      "SubscriptionId": "sub-id-1",
      "ComplianceStatus": "NonCompliant",
      "AssignedLicense": null
    }
  ],
  "OrphanedLicenses": [
    {
      "LicenseId": "/subscriptions/.../licenses/esu-oldserver",
      "LicenseName": "esu-oldserver",
      "ResourceGroup": "rg-prod"
    }
  ],
  "ExpiringSoonLicenses": []
}
```

Additionally, non-compliant machines trigger:
- `Write-Warning` per machine: `"Non-compliant machine: '<name>' (RG: <rg>, Sub: <sub>) - no ESU license assigned"`
- `Write-Error`: `"ESU_COMPLIANCE_ALERT: <count> of <total> eligible machine(s) are non-compliant."`

### Scheduling

**Recommended:** Daily, scheduled to run **after** `Sync-EsuLicenses` (e.g., 09:00 UTC). Can also be run on-demand for ad-hoc compliance checks.

### Error Handling

- **Top-level `try/catch`:** Catches unrecoverable errors (authentication, module import, Resource Graph failures) and fails the entire job.
- **Compliance alerts:** Non-compliant machines trigger `Write-Error` with the `ESU_COMPLIANCE_ALERT` prefix, which can be used for Azure Monitor alert rules.
- **100% compliance:** If no eligible machines exist, compliance percentage defaults to `100.0`.

### Examples

**Running from Azure Portal:**

1. Navigate to your Automation Account → **Runbooks** → **Report-EsuCompliance**.
2. Click **Start**.
3. Optionally provide `SubscriptionId` values.
4. Review the JSON output in the **Output** tab.
5. Check the **Warnings** and **Errors** tabs for compliance alerts.

**Running via PowerShell:**

```powershell
# Full compliance report across all subscriptions
Start-AzAutomationRunbook -AutomationAccountName 'my-automation' `
    -ResourceGroupName 'rg-automation' `
    -Name 'Report-EsuCompliance'

# Scope to specific subscriptions
Start-AzAutomationRunbook -AutomationAccountName 'my-automation' `
    -ResourceGroupName 'rg-automation' `
    -Name 'Report-EsuCompliance' `
    -Parameters @{ SubscriptionId = 'sub-id-1','sub-id-2' }

# Run and wait for output
$job = Start-AzAutomationRunbook -AutomationAccountName 'my-automation' `
    -ResourceGroupName 'rg-automation' `
    -Name 'Report-EsuCompliance' -Wait
$output = Get-AzAutomationJobOutput -AutomationAccountName 'my-automation' `
    -ResourceGroupName 'rg-automation' -Id $job.JobId -Stream Output
$report = $output.Summary | ConvertFrom-Json
```

### Troubleshooting

| Issue | Cause | Solution |
|-------|-------|----------|
| `ESU_COMPLIANCE_ALERT` error in job | One or more eligible machines lack ESU licenses. | Run `Apply-EsuLicense` to assign missing licenses. |
| Orphaned license count is high | Licenses exist for machines that have been decommissioned. | Run `Sync-EsuLicenses` to clean up orphaned licenses. |
| `ExpiringSoon` licenses reported | Licenses are within 30 days of expiration. | Review license renewal plans; contact Microsoft for ESU renewal. |
| JSON output is empty or malformed | An error occurred before the report could be generated. | Check the **Errors** tab in the job for the root cause. |
| Compliance percentage is 100% but no machines exist | No ESU-eligible machines were found. | Verify Arc machines exist and run `Discover-ArcEsuMachines`. |

---

## Runbook Execution Order

The runbooks are designed to run in the following sequence:

```
Discovery → Apply → Sync → Report
```

| Step | Runbook | Purpose | Recommended Time |
|------|---------|---------|-----------------|
| 1 | **Discover-ArcEsuMachines** | Find eligible machines and tag them `ESU:Required`. | 06:00 UTC |
| 2 | **Apply-EsuLicense** | Create and assign ESU licenses to tagged machines. | 07:00 UTC |
| 3 | **Sync-EsuLicenses** | Clean up stale licenses and detect recommissioned machines. | 08:00 UTC |
| 4 | **Report-EsuCompliance** | Generate compliance report and alert on gaps. | 09:00 UTC |

**Why this order matters:**

- **Discover** must run first so that newly onboarded machines are tagged before Apply looks for them.
- **Apply** must run after Discover so that all eligible machines have the `ESU:Required` tag.
- **Sync** runs after Apply to clean up licenses for machines that have been decommissioned since the last run and to identify any machines that still need licensing.
- **Report** runs last to provide an accurate compliance snapshot after all changes have been applied.

Each runbook is also safe to run independently or on-demand.

---

## Dependencies

The following table shows which helper functions from `EsuHelpers.psm1` each runbook uses:

| Helper Function | Discover-ArcEsuMachines | Apply-EsuLicense | Sync-EsuLicenses | Report-EsuCompliance |
|-----------------|:-----------------------:|:----------------:|:----------------:|:--------------------:|
| `Connect-AutomationAccount` | ✓ | ✓ | ✓ | ✓ |
| `Get-ArcMachinesByTag` | ✗ (via `Get-EsuEligibleMachines`) | ✓ | ✗ (via `Get-EsuEligibleMachines`) | ✗ (via `Get-EsuEligibleMachines`) |
| `Get-ArcMachinesByOs` | ✗ (via `Get-EsuEligibleMachines`) | ✗ | ✗ (via `Get-EsuEligibleMachines`) | ✗ (via `Get-EsuEligibleMachines`) |
| `Get-EsuEligibleMachines` | ✓ | ✗ | ✓ | ✓ |
| `Get-ExistingEsuLicenses` | ✗ | ✓ | ✓ | ✓ |
| `Set-MachineEsuTag` | ✓ | ✗ | ✗ | ✗ |

**Additional Az module dependencies per runbook:**

| Az Module | Discover | Apply | Sync | Report |
|-----------|:--------:|:-----:|:----:|:------:|
| `Az.Accounts` | ✓ | ✓ | ✓ | ✓ |
| `Az.ResourceGraph` | ✓ | ✓ | ✓ | ✓ |
| `Az.Resources` | ✓ | ✓ | ✓ | ✓ |
| `Az.ConnectedMachine` | ✗ | ✓ | ✓ | ✗ |
