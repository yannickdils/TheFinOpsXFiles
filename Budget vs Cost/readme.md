# Azure Budget Guardian: Automated Budget vs. Actual Cost Management Solution

Gain complete visibility and control over your Azure spending with this automated solution that tracks actual costs against budgets across all your subscriptions. Using PowerShell, Bicep, and Log Analytics, this system helps you monitor spending trends, identify budget overruns, and optimize your cloud investments—all with zero maintenance.

The solution collects daily cost data across all your subscriptions, compares it against budgets, and stores everything in a Log Analytics workspace for easy reporting and visualization. The best part? It's completely automated and secure, using managed identities instead of credentials.

## Current Challenges in Azure Cost Management

Organizations operating in Azure often face several significant challenges when trying to monitor and control their cloud spending:

### Fragmented Budget Visibility

Azure's native budgeting functionality operates at the individual management group, subscription or resource group level, there is also a significant difference in reporting capacilities between Enterprise Agreements, CSP & PAYG commitments, making it difficult to:

- Get a centralized view of all budgets across multiple subscriptions
- Track overall organizational spending against planned budgets
- Generate a unified report showing budget compliance across the entire environment

### Limited Budget vs. Actual Reporting

While Azure Cost Management provides actual cost data, there are key limitations:

- No built-in dashboards that effectively compare budget vs. actual spending across subscriptions
- Missing historical trending of budget compliance over time
- Limited options for automated alerting based on budget-to-actual ratios

### Manual Processes and Data Silos

Without a custom solution, organizations typically resort to:

- Manually exporting data from multiple subscriptions
- Creating spreadsheets to combine budget and actual costs
- Building ad-hoc reporting that requires regular maintenance
- Developing separate processes for alerting when budgets are approached

### Delayed Insights and Reaction Time

The manual nature of cross-subscription budget monitoring leads to:

- Discovering budget overruns days or weeks after they occur
- Slow reaction time to spending anomalies
- Inability to proactively adjust resources before budgets are exceeded
- Difficulties in attributing costs to specific teams or projects

This solution addresses these challenges by providing an automated, centralized system that collects both budget and actual cost data across all subscriptions, compares them in real-time, and makes this information accessible through customizable dashboards and alerts.



## What We're Building

The solution consists of:

- A resource group in your management subscription
- An Azure Automation account with a system-assigned managed identity
- A Log Analytics workspace with a custom table for cost data
- A Data Collection Rule (DCR) and Data Collection Endpoint (DCE) for modern log ingestion
- A PowerShell runbook that runs daily to collect cost data
- Proper RBAC permissions to access cost data across subscriptions

At a high level, the runbook connects to Azure using the system-assigned managed identity, retrieves cost data for all accessible subscriptions, and streams it to Log Analytics using the Azure Monitor Logs Ingestion API via DCR/DCE. You can then query this data using KQL or visualize it in dashboards.

## Prerequisites

Before you begin, make sure you have:

- PowerShell 7.x with the following modules installed:
  - Az.Resources
  - Az.Automation
  - Az.OperationalInsights
  - Az.Monitor
- Contributor access to a management subscription where you'll deploy the solution
- Global Administrator or User Access Administrator to assign roles across subscriptions

## Project Structure

Here's the file structure for the solution with links to each file:

```
Budget vs Cost/
├── deploy.ps1                  # Main deployment script
├── main.bicep                  # Main Bicep template (subscription level)
├── main.parameters.json        # Parameters for Bicep deployment
├── post-deploy-roles.ps1       # Script to assign necessary RBAC roles
├── resources.bicep             # Resource definitions for Bicep
└── Script/
    └── RetrieveConsumptionUpdate.ps1  # The actual runbook script
```

### File References

- [**deploy.ps1**](#deployment-script-details) - Main deployment script that orchestrates the entire setup
- [**main.bicep**](#bicep-templates) - Subscription-level Bicep template that creates the resource group and calls the resources module
- [**main.parameters.json**](#parameters-configuration) - Parameters file that defines resource names and tags
- [**post-deploy-roles.ps1**](#rbac-configuration) - Script that assigns necessary RBAC roles to the system-assigned identity
- [**resources.bicep**](#resource-definitions) - Resource group-level Bicep template defining all Azure resources
- [**Script/RetrieveConsumptionUpdate.ps1**](#runbook-script-details) - PowerShell runbook that collects cost data and uploads it to Log Analytics

## How It Works

### 1. Bicep Infrastructure-as-Code {#bicep-templates}

Our solution uses Bicep to define and deploy all the required Azure resources:

- [`main.bicep`](main.bicep) creates the resource group and invokes the resources module
- [`resources.bicep`](resources.bicep) defines all individual resources:
  - Azure Automation account with a system-assigned managed identity
  - Log Analytics workspace with a custom table schema
  - Data Collection Endpoint (DCE) for modern log ingestion
  - Data Collection Rule (DCR) to define the data flow
  - Automation variables to store connection details
  - Role assignments for secure access

### 2. Role Assignments {#rbac-configuration}

The [`post-deploy-roles.ps1`](post-deploy-roles.ps1) script assigns proper RBAC roles to the Automation Account's managed identity:

- Cost Management Reader on all subscriptions
- Log Analytics Contributor and Reader for the Log Analytics workspace
- Monitoring Metrics Publisher for both the DCR and DCE

### 3. PowerShell Runbook {#runbook-script-details}

The core functionality is in the [`Script/RetrieveConsumptionUpdate.ps1`](Script/RetrieveConsumptionUpdate.ps1) runbook script, which:

1. Authenticates using the system-assigned managed identity
2. Gets a list of all accessible subscriptions
3. For each subscription:
   - Retrieves cost data for the specified period
   - Gets any configured budgets
   - Calculates budget usage percentages
4. Prepares a structured dataset with all the cost information
5. Uses the modern Azure Monitor Logs Ingestion API to stream data directly to Log Analytics

### 4. Data Storage and Querying

The cost data is stored in a custom Log Analytics table named `CostManagementData_CL`, which you can query using KQL.

## Deployment Instructions {#deployment-script-details}

To deploy the solution:

1. Ensure you have all the prerequisites installed
2. Clone or download this repository
3. Open PowerShell as an administrator
4. Navigate to the repository folder
5. Connect to Azure using `Connect-AzAccount`
6. Run the deployment script:

```powershell
.\deploy.ps1
```

The [`deploy.ps1`](deploy.ps1) script will take a few minutes to execute, during which it will:

- Create or update all required resources
- Upload and publish the runbook script
- Schedule the runbook to run daily
- Configure Automation Account variables
- Set up all necessary RBAC permissions

## Querying the Cost Data

Once the runbook has executed successfully, you can query the data in Log Analytics. Here are some useful KQL queries:

### Basic query to see all cost data

```kql
CostManagementData_CL
| sort by TimeGenerated desc
```

### Monthly costs by subscription

```kql
CostManagementData_CL
| where TimeGenerated > ago(90d)
| summarize arg_max(TimeGenerated, *) by SubscriptionName, Month, Year
| project SubscriptionName, CostAmount, BudgetAmount, BudgetUsedPercent, Month, Year
| sort by Year desc, Month desc, CostAmount desc
```

### Subscriptions over budget

```kql
CostManagementData_CL
| where TimeGenerated > ago(7d)
| where BudgetAmount > 0
| where CostAmount > BudgetAmount
| project TimeGenerated, SubscriptionName, CostAmount, BudgetAmount, BudgetUsedPercent
| sort by BudgetUsedPercent desc
```

## Creating Visualizations

You can create rich visualizations using Azure Monitor Workbooks:

1. Go to your Log Analytics workspace
2. Navigate to "Workbooks" in the left menu
3. Click "New"
4. Add a new query with one of the KQL examples above
5. Change the visualization type (e.g., Bar chart, Pie chart)
6. Save and pin the workbook to a dashboard

## Technical Details

### Resource Definitions {#resource-definitions}

The [`resources.bicep`](resources.bicep) file defines all the Azure resources needed for this solution:

- **Automation Account**: Hosts and runs the PowerShell runbook
- **Log Analytics Workspace**: Stores and indexes the cost data
- **Custom Table**: Defines the schema for the cost data
- **Data Collection Endpoint (DCE)**: Provides the ingestion endpoint
- **Data Collection Rule (DCR)**: Configures the data flow to Log Analytics
- **Automation Variables**: Store configuration for the runbook

### Modern Log Ingestion (DCR/DCE)

This solution uses Azure Monitor's modern Data Collection Rules (DCR) and Data Collection Endpoints (DCE) for log ingestion:

- **DCE**: Provides the endpoint URL for data ingestion
- **DCR**: Defines the data stream details and destination
- **Automation Variables**: Store the DCE endpoint and DCR immutable ID for the runbook

The runbook uses the DCE/DCR to send data via the Azure Monitor Logs Ingestion API, which is the preferred method for custom logs going forward.

### RBAC Security Model

The solution uses a least-privilege security model:

- System-assigned managed identity instead of credentials or service principals
- Fine-grained RBAC permissions only for needed operations
- Cost Management Reader role instead of broader permissions

### Parameters Configuration {#parameters-configuration}

The solution uses the [`main.parameters.json`](main.parameters.json) file to configure resource names, locations, and tags. You can modify this file to customize the deployment for your environment.

### Currency Configuration

The solution defaults to using EUR as the currency. To change this:

1. Open [`Script/RetrieveConsumptionUpdate.ps1`](Script/RetrieveConsumptionUpdate.ps1)
2. Find the line `Currency = "EUR"` (around line 101)
3. Replace "EUR" with your local currency code (e.g., "USD", "GBP", etc.)

## Troubleshooting

### Common Issues

**Error: "Required PowerShell module is not installed"**  
Install the missing module using `Install-Module -Name <ModuleName> -Force`

**Error: "You are not logged in to Azure"**  
Connect to Azure using `Connect-AzAccount`

**Error: "Could not find Log Analytics workspace"**  
Verify the workspace name in `main.parameters.json` matches your environment

**Error: "Authentication failed"**  
Ensure the Automation Account has its system-assigned identity enabled

**Error: "Failed to send data to Azure Monitor"**  
Check that the DCR and DCE are properly configured and the managed identity has the correct permissions

### Checking Runbook Status

To check if your runbook is running successfully:

1. Go to the Azure Portal
2. Navigate to your Automation Account
3. Click on "Jobs" under "Process Automation"
4. Look for the latest execution of "AnalyzeCostManagementData"
5. Check the output and any error messages

## Extending the Solution

You can extend this solution by:

- Creating custom alerts when costs exceed thresholds
- Building Power BI dashboards connected to Log Analytics
- Adding more granular data collection (e.g., resource group level costs)
- Integrating with other systems through Logic Apps or Azure Functions
- Implementing recommendations for cost optimization

## Conclusion

This automated Azure cost management solution provides a comprehensive view of your cloud spending across all subscriptions. By leveraging infrastructure-as-code with Bicep, secure authentication with managed identities, and modern log ingestion with DCR/DCE, you get a robust and maintainable solution that can help you monitor and control your Azure costs effectively.

---

*Note: This solution is provided as-is without warranty of any kind. Always test in a non-production environment first.*