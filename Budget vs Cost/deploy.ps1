#Requires -Modules Az.Resources, Az.Automation, Az.OperationalInsights, Az.Monitor

param(
    [Parameter(Mandatory = $false)]
    [string]$Location = "westeurope"
)

# Display deployment parameters
Write-Host "Deploying with parameters:" -ForegroundColor Cyan
Write-Host "  Location: $Location"
Write-Host "  Note: Full resource naming is defined in main.parameters.json"
Write-Host ""

# Check if Az PowerShell modules are installed
$requiredModules = @("Az.Resources", "Az.Automation", "Az.OperationalInsights", "Az.Monitor")
foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Error "Required PowerShell module '$module' is not installed. Please install it using: Install-Module -Name $module -Force"
        exit 1
    }
}

# Check if user is logged in to Azure
try {
    Write-Host "Checking Azure login status..." -ForegroundColor Cyan
    $context = Get-AzContext
    if (-not $context) {
        Write-Error "You are not logged in to Azure. Please run 'Connect-AzAccount' first."
        exit 1
    }
    Write-Host "Logged in as $($context.Account) to subscription $($context.Subscription.Name)"
} 
catch {
    Write-Error "Error checking Azure login: $_"
    exit 1
}

# Deploy the main Bicep template at subscription level
try {
    Write-Host "Deploying main Bicep template at subscription level..." -ForegroundColor Cyan
    
    $deploymentParams = @{
        Name                  = "deployment-finops-$(Get-Date -Format 'yyyyMMddHHmmss')"
        Location              = $Location
        TemplateFile          = ".\main.bicep"
        TemplateParameterFile = ".\main.parameters.json"
    }
    
    # Deploy at subscription level
    $deployment = New-AzDeployment @deploymentParams
    
    # Extract resource information from the deployment output
    $resourceGroupName = $deployment.Outputs.resourceGroupName.Value
    $automationAccountName = $deployment.Outputs.automationAccountName.Value
    $logAnalyticsWorkspaceName = $deployment.Outputs.logAnalyticsWorkspaceName.Value
    $dataCollectionRuleName = $deployment.Outputs.dataCollectionRuleName.Value
    $dataCollectionEndpointName = $deployment.Outputs.dataCollectionEndpointName.Value
    $dcrImmutableId = $deployment.Outputs.dcrImmutableId.Value
    $dceEndpoint = $deployment.Outputs.dceEndpoint.Value
    
    # Validate that we received the required outputs from the deployment
    if ([string]::IsNullOrEmpty($resourceGroupName) -or 
        [string]::IsNullOrEmpty($automationAccountName) -or 
        [string]::IsNullOrEmpty($logAnalyticsWorkspaceName) -or
        [string]::IsNullOrEmpty($dataCollectionRuleName) -or
        [string]::IsNullOrEmpty($dataCollectionEndpointName) -or
        [string]::IsNullOrEmpty($dcrImmutableId) -or
        [string]::IsNullOrEmpty($dceEndpoint)) {
        
        Write-Error "One or more required outputs from the deployment are empty or missing."
        Write-Host "ResourceGroupName: $resourceGroupName"
        Write-Host "AutomationAccountName: $automationAccountName"
        Write-Host "LogAnalyticsWorkspaceName: $logAnalyticsWorkspaceName"
        Write-Host "DataCollectionRuleName: $dataCollectionRuleName"
        Write-Host "DataCollectionEndpointName: $dataCollectionEndpointName"
        Write-Host "DCR Immutable ID: $dcrImmutableId"
        Write-Host "DCE Endpoint: $dceEndpoint"
        exit 1
    }
    
    Write-Host "Main deployment completed successfully!" -ForegroundColor Green
    Write-Host "Resource Group: $resourceGroupName"
    Write-Host "Automation Account: $automationAccountName"
    Write-Host "Log Analytics Workspace: $logAnalyticsWorkspaceName"
    Write-Host "Data Collection Rule: $dataCollectionRuleName"
    Write-Host "Data Collection Endpoint: $dataCollectionEndpointName"
    Write-Host "DCR Immutable ID: $dcrImmutableId"
    Write-Host "DCE Endpoint: $dceEndpoint"
    
    # Set up role assignments using PowerShell
    if (Test-Path -Path ".\post-deploy-roles.ps1") {
        Write-Host "Running post-deployment role assignments..." -ForegroundColor Cyan
        & ".\post-deploy-roles.ps1" -ResourceGroupName $resourceGroupName -AutomationAccountName $automationAccountName -LogAnalyticsWorkspaceName $logAnalyticsWorkspaceName -DataCollectionRuleName $dataCollectionRuleName -DataCollectionEndpointName $dataCollectionEndpointName
        Write-Host "Post-deployment role assignments completed successfully!" -ForegroundColor Green
    }
    else {
        Write-Host "Warning: post-deploy-roles.ps1 script not found. The Automation Account won't have access to cost data." -ForegroundColor Yellow
        Write-Host "Please assign the Cost Management Reader role to the Automation Account's system-assigned identity manually through the Azure Portal." -ForegroundColor Yellow
        Write-Host "Also assign the Monitoring Metrics Publisher role to the Automation Account's system-assigned identity for both DCR and DCE." -ForegroundColor Yellow
    }
    
}
catch {
    Write-Error "Error deploying main Bicep template: $_"
    exit 1
}

# Get the Automation Account details
try {
    $automationAccount = Get-AzAutomationAccount -ResourceGroupName $resourceGroupName -Name $automationAccountName
}
catch {
    Write-Error "Error retrieving Automation Account details: $_"
    exit 1
}

# Ensure the Automation Variables are set
try {
    Write-Host "Setting up Automation Variables..." -ForegroundColor Cyan
    
    # Set or update dceEndpoint variable
    $dceEndpointVar = Get-AzAutomationVariable -ResourceGroupName $resourceGroupName -AutomationAccountName $automationAccountName -Name "dceEndpoint" -ErrorAction SilentlyContinue
    if (-not $dceEndpointVar) {
        New-AzAutomationVariable -ResourceGroupName $resourceGroupName -AutomationAccountName $automationAccountName -Name "dceEndpoint" -Value $dceEndpoint -Encrypted $false
        Write-Host "  Created dceEndpoint variable" -ForegroundColor Green
    } else {
        Set-AzAutomationVariable -ResourceGroupName $resourceGroupName -AutomationAccountName $automationAccountName -Name "dceEndpoint" -Value $dceEndpoint -Encrypted $false
        Write-Host "  Updated dceEndpoint variable" -ForegroundColor Green
    }
    
    # Set or update dcrImmutableId variable
    $dcrImmutableIdVar = Get-AzAutomationVariable -ResourceGroupName $resourceGroupName -AutomationAccountName $automationAccountName -Name "dcrImmutableId" -ErrorAction SilentlyContinue
    if (-not $dcrImmutableIdVar) {
        New-AzAutomationVariable -ResourceGroupName $resourceGroupName -AutomationAccountName $automationAccountName -Name "dcrImmutableId" -Value $dcrImmutableId -Encrypted $false
        Write-Host "  Created dcrImmutableId variable" -ForegroundColor Green
    } else {
        Set-AzAutomationVariable -ResourceGroupName $resourceGroupName -AutomationAccountName $automationAccountName -Name "dcrImmutableId" -Value $dcrImmutableId -Encrypted $false
        Write-Host "  Updated dcrImmutableId variable" -ForegroundColor Green
    }
}
catch {
    Write-Error "Error setting up Automation Variables: $_"
    exit 1
}

# Upload PowerShell runbook to Automation Account
try {
    Write-Host "Uploading PowerShell runbook to Automation Account..." -ForegroundColor Cyan
    
    # Delete the runbook if it already exists
    $existingRunbook = Get-AzAutomationRunbook -AutomationAccountName $automationAccountName -ResourceGroupName $resourceGroupName -Name "AnalyzeCostManagementData" -ErrorAction SilentlyContinue
    if ($existingRunbook) {
        Remove-AzAutomationRunbook -AutomationAccountName $automationAccountName -ResourceGroupName $resourceGroupName -Name "AnalyzeCostManagementData" -Force
    }
    
    # Create and import the runbook
    Import-AzAutomationRunbook -AutomationAccountName $automationAccountName -ResourceGroupName $resourceGroupName -Name "AnalyzeCostManagementData" -Type "PowerShell" -Path ".\Script\RetrieveConsumptionUpdate.ps1" -Force | Out-Null
    
    Write-Host "Publishing runbook..." -ForegroundColor Cyan
    Publish-AzAutomationRunbook -AutomationAccountName $automationAccountName -ResourceGroupName $resourceGroupName -Name "AnalyzeCostManagementData" | Out-Null
}
catch {
    Write-Error "Error uploading PowerShell runbook: $_"
    exit 1
}

# Create schedule for the runbook to run daily
try {
    Write-Host "Creating schedule for the runbook to run daily..." -ForegroundColor Cyan
    
    # Remove existing schedule if it exists
    $existingSchedule = Get-AzAutomationSchedule -AutomationAccountName $automationAccountName -ResourceGroupName $resourceGroupName -Name "DailyCostAnalysis" -ErrorAction SilentlyContinue
    if ($existingSchedule) {
        Remove-AzAutomationSchedule -AutomationAccountName $automationAccountName -ResourceGroupName $resourceGroupName -Name "DailyCostAnalysis" -Force
    }
    
    # Create new schedule
    $startTime = (Get-Date).AddDays(1).Date.AddHours(1).ToUniversalTime()
    New-AzAutomationSchedule -AutomationAccountName $automationAccountName -ResourceGroupName $resourceGroupName -Name "DailyCostAnalysis" -StartTime $startTime -TimeZone "UTC" -DayInterval 1 | Out-Null
    
    # Create runbook parameters and register job
    Write-Host "Creating runbook parameters..." -ForegroundColor Cyan
    
    $params = @{
        "LogAnalyticsWorkspaceName" = $logAnalyticsWorkspaceName
        "DaysToAnalyze" = 30
        "DataCollectionRuleName" = $dataCollectionRuleName
    }
    
    Write-Host "Configured parameters:" -ForegroundColor Yellow
    Write-Host "  LogAnalyticsWorkspaceName: $logAnalyticsWorkspaceName" 
    Write-Host "  DaysToAnalyze: 30"
    Write-Host "  DataCollectionRuleName: $dataCollectionRuleName"
    
    # Remove existing job schedule if it exists
    Get-AzAutomationScheduledRunbook -AutomationAccountName $automationAccountName -ResourceGroupName $resourceGroupName | Where-Object { $_.ScheduleName -eq "DailyCostAnalysis" } | ForEach-Object {
        Unregister-AzAutomationScheduledRunbook -AutomationAccountName $automationAccountName -ResourceGroupName $resourceGroupName -RunbookName $_.RunbookName -ScheduleName $_.ScheduleName -Force
    }
    
    # Register new job schedule
    Register-AzAutomationScheduledRunbook -AutomationAccountName $automationAccountName -ResourceGroupName $resourceGroupName -RunbookName "AnalyzeCostManagementData" -ScheduleName "DailyCostAnalysis" -Parameters $params | Out-Null
}
catch {
    Write-Error "Error creating schedule: $_"
    exit 1
}

Write-Host "Setup complete! The runbook will run daily and collect cost data for the past 30 days." -ForegroundColor Green
Write-Host ""
Write-Host "You can manually run the runbook with the following command:" -ForegroundColor Yellow
Write-Host "Start-AzAutomationRunbook -AutomationAccountName '$automationAccountName' -ResourceGroupName '$resourceGroupName' -Name 'AnalyzeCostManagementData' -Parameters @{LogAnalyticsWorkspaceName='$logAnalyticsWorkspaceName'; DataCollectionRuleName='$dataCollectionRuleName'}"
Write-Host ""
Write-Host "To query the cost data in Log Analytics, use the following KQL query:" -ForegroundColor Yellow
Write-Host "CostManagementData_CL | sort by TimeGenerated desc"
Write-Host ""
Write-Host "Azure Monitor Logs Ingestion configuration:" -ForegroundColor Yellow
Write-Host "  DCE Endpoint: $dceEndpoint"
Write-Host "  DCR Immutable ID: $dcrImmutableId"
Write-Host "  Stream Name: Custom-CostManagementData"
Write-Host ""
Write-Host "These values are stored as Automation Variables in your Automation Account." -ForegroundColor Yellow