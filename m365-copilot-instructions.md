Azure Arc provides a way to **attest Software Assurance (SA) coverage** for servers through its **License Profile** feature. Here’s how it works:

***

### **1. License Profile in Azure Arc**

*   When you onboard a server to Azure Arc, the resource type is `Microsoft.HybridCompute/machines`.
*   Each Arc-enabled machine has a **licenseProfile** property that can store licensing details, including:
    *   `softwareAssurance`: Boolean value (`true` or `false`) indicating whether the server is covered by SA.
    *   `licenseType`: Specifies if the server uses Azure Hybrid Benefit or other licensing models.

***

### **2. How Attestation Happens**

*   You (or your automation) set the **licenseProfile.softwareAssurance** property during or after onboarding.
*   This attestation is **not automatic**; it requires:
    *   Manual update via **Azure Portal**, **Azure CLI**, or **PowerShell**.
    *   Or automated enforcement using **Azure Policy**.

***

### **3. Why This Matters**

*   Microsoft uses this attestation to validate eligibility for:
    *   **Hybrid Use Benefit** (cost savings).
    *   **Extended Security Updates (ESU)**.
*   It also helps with compliance reporting and cost optimization.

***

### **4. How to Set SA Attestation**

*   **Azure CLI Example:**

```bash
az connectedmachine update \
  --name <ArcServerName> \
  --resource-group <ResourceGroupName> \
  --set licenseProfile.softwareAssurance=true
```

*   **PowerShell Example:**

```powershell
Update-AzConnectedMachine `
  -MachineName "<ArcServerName>" `
  -ResourceGroupName "<ResourceGroupName>" `
  -LicenseProfile @{ softwareAssurance = $true }
```

***

✅ Do you want me to **give you a complete guide with:**

*   **Step-by-step portal instructions** for setting SA attestation?
*   **Azure Policy JSON template** to enforce SA attestation for all new Arc servers?  
    Or both combined into a **compliance automation playbook**?
