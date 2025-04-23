param(
    [Parameter(Mandatory = $true)]
    [string]$LogAnalyticsWorkspaceName,
    
    [Parameter(Mandatory = $false)]
    [int]$DaysToAnalyze = 30,
    
    [Parameter(Mandatory = $false)]
    [string]$DataCollectionRuleName
)

# Get the current date
$now = Get-Date
$month = $now.ToString("MMMM")   # e.g., April
$year = $now.Year

# Authentication using system-assigned managed identity
try {
    # Ensures no inherited AzContext 
    Disable-AzContextAutosave -Scope Process

    # Use the system-assigned identity without any additional parameters
    Write-Output "Connecting using system-assigned managed identity..."
    $AzureContext = (Connect-AzAccount -Identity).context
    
    # Set and store context
    $AzureContext = Set-AzContext -SubscriptionName $AzureContext.Subscription -DefaultProfile $AzureContext
    
    Write-Output "Successfully connected using system-assigned identity"
} catch {
    Write-Error "Failed to connect using system-assigned managed identity: $_"
    throw "Authentication failed. Please ensure system-assigned identity is enabled on the Automation Account."
}

# Check Az module versions for debugging
Write-Output "Checking Az module versions:"
Get-Module -Name Az* -ListAvailable | Where-Object { $_.Name -in 'Az.Accounts', 'Az.Resources', 'Az.Monitor' } | ForEach-Object {
    Write-Output "  - $($_.Name): $($_.Version)"
}

# Get all subscriptions the identity has access to
$subs = Get-AzSubscription -ErrorAction Stop
Write-Output "Found $($subs.Count) subscriptions"

# Create output array for all subscription data
$costData = @()

foreach ($sub in $subs) {
    Write-Output "Processing subscription: $($sub.Name) ($($sub.Id))"
    
    # Set context to current subscription
    Set-AzContext -SubscriptionId $sub.Id | Out-Null
    
    try {
        # Get cost for specified period
        Write-Output "Retrieving cost data for the past $DaysToAnalyze days..."
        $startDate = $now.AddDays(-$DaysToAnalyze)
        Write-Output "Date range: $startDate to $now"
        
        $costDetails = Get-AzConsumptionUsageDetail -StartDate $startDate -EndDate $now -ErrorAction Stop
        
        if ($costDetails -and $costDetails.Count -gt 0) {
            Write-Output "Retrieved $($costDetails.Count) cost line items"
            $totalCost = $costDetails | Measure-Object -Property PretaxCost -Sum | Select-Object -ExpandProperty Sum
            Write-Output "Total cost: $totalCost"
        } else {
            Write-Output "No cost data found for the specified period"
            $totalCost = 0
        }
        
        # Get budget if available
        try {
            $budget = Get-AzConsumptionBudget -ErrorAction Stop | Select-Object -First 1
            if ($budget) {
                Write-Output "Found budget: $($budget.Amount) $($budget.TimeGrain)"
                $budgetAmount = $budget.Amount
            } else {
                Write-Output "No budget found"
                $budgetAmount = $null
            }
        } catch {
            Write-Output "Error retrieving budget: $_"
            $budgetAmount = $null
        }
        
        # Calculate budget usage
        $budgetUsed = if ($budget -and $budget.Amount -ne 0) {
            ($totalCost / $budget.Amount) * 100
        } else {
            $null
        }
        
        # Add to output collection
        $costData += [PSCustomObject]@{
            TimeGenerated    = $now.ToUniversalTime()
            Year             = $year
            Month            = $month
            SubscriptionName = $sub.Name
            SubscriptionId   = $sub.Id
            CostAmount       = $totalCost
            BudgetAmount     = $budgetAmount
            BudgetUsedPercent = $budgetUsed
            Currency         = "EUR" # Assuming EUR as currency
            Status           = $sub.State
            PeriodStart      = $startDate.ToString("yyyy-MM-dd")
            PeriodEnd        = $now.ToString("yyyy-MM-dd")
        }
        
        Write-Output "Added cost data for subscription $($sub.Name): Cost = $totalCost EUR, Budget = $budgetAmount EUR"
    }
    catch {
        Write-Error "Error processing subscription $($sub.Name): $_"
    }
}

Write-Output "Processed $($costData.Count) subscriptions"

# Upload data to Log Analytics using DCE and DCR
if ($costData.Count -gt 0) {
    try {
        Write-Output "Finding Log Analytics workspace: $LogAnalyticsWorkspaceName"
        
        # Find the Log Analytics workspace across all subscriptions
        $workspace = $null
        $workspaceSubscriptionId = $null
        
        foreach ($sub in $subs) {
            Write-Output "Looking for workspace in subscription: $($sub.Name)"
            Set-AzContext -SubscriptionId $sub.Id | Out-Null
            
            $foundWorkspace = Get-AzOperationalInsightsWorkspace -ErrorAction SilentlyContinue | 
                Where-Object { $_.Name -eq $LogAnalyticsWorkspaceName }
            
            if ($foundWorkspace) {
                $workspace = $foundWorkspace
                $workspaceSubscriptionId = $sub.Id
                Write-Output "Found workspace in subscription: $($sub.Name), resource group: $($workspace.ResourceGroupName)"
                break
            }
        }
        
        if (-not $workspace) {
            throw "Could not find Log Analytics workspace: $LogAnalyticsWorkspaceName in any accessible subscription"
        }
        
        # Set context to the subscription containing the workspace
        Write-Output "Setting context to workspace subscription: $workspaceSubscriptionId"
        Set-AzContext -SubscriptionId $workspaceSubscriptionId | Out-Null
        
        # Get DCE endpoint and DCR immutable ID from automation variables
        try {
            $dceEndpoint = Get-AutomationVariable -Name "dceEndpoint" -ErrorAction Stop
            $dcrImmutableId = Get-AutomationVariable -Name "dcrImmutableId" -ErrorAction Stop
            $tableName = Get-AutomationVariable -Name "tableName" -ErrorAction SilentlyContinue
            
            # Remove quotes if present
            $dceEndpoint = $dceEndpoint.Trim('"')
            $dcrImmutableId = $dcrImmutableId.Trim('"')
            
            if ($tableName) {
                $tableName = $tableName.Trim('"')
            } else {
                $tableName = "CostManagementData_CL"
            }
            
            Write-Output "Retrieved configuration from automation variables:"
            Write-Output "  - DCE Endpoint: $dceEndpoint"
            Write-Output "  - DCR Immutable ID: $dcrImmutableId"
            Write-Output "  - Table Name: $tableName"
        }
        catch {
            Write-Error "Failed to retrieve configuration from automation variables: $_"
            throw "Make sure dceEndpoint and dcrImmutableId automation variables are configured in your Automation Account."
        }
        
        # Convert data to JSON - ensuring it's an array
        # PowerShell 5.1 (Azure Automation) doesn't have -AsArray parameter, 
        # so we need to ensure it's an array format manually
        if ($costData.Count -eq 1) {
            # Force array format by wrapping the single object in an array
            $jsonData = "[$($costData | ConvertTo-Json -Depth 5 -Compress)]"
        } else {
            # Multiple items will automatically be formatted as an array
            $jsonData = $costData | ConvertTo-Json -Depth 5 -Compress
        }
        
        Write-Output "Data payload size: $($jsonData.Length) characters"
        Write-Output "First record sample:"
        $firstRecord = $costData[0] | ConvertTo-Json
        Write-Output $firstRecord
        
        # Create backup of the data in case of failure
        $backupFilePath = Join-Path -Path $env:TEMP -ChildPath "CostData_$(Get-Date -Format 'yyyyMMddHHmmss').json"
        $jsonData | Out-File -FilePath $backupFilePath
        Write-Output "Created backup of cost data at: $backupFilePath"
        
        # Get authentication token for Logs Ingestion API
        Write-Output "Getting authentication token for Logs Ingestion API..."
        $token = (Get-AzAccessToken -ResourceUrl "https://monitor.azure.com/").Token
        
        # Construct the API URL - using the new DCR format without stream name
        $uri = "$dceEndpoint/dataCollectionRules/$dcrImmutableId/streams/Custom-$tableName`?api-version=2023-01-01"
        Write-Output "API URI: $uri"
        
        # Define headers - including the auth token in headers
        $headers = @{
            "Content-Type" = "application/json"
            "Authorization" = "Bearer $token"
        }
        
        Write-Output "HTTP Headers:"
        foreach ($key in $headers.Keys) {
            if ($key -eq "Authorization") {
                # Don't log the full auth token for security
                Write-Output "  - $($key): Bearer [Token hidden]"
            } else {
                Write-Output "  - $($key): $($headers[$key])"
            }
        }
        
        # Send data to the DCR ingestion endpoint
        Write-Output "Sending $($costData.Count) records to Logs Ingestion API..."
        
        try {
            # Using Invoke-RestMethod with headers for authentication (older style)
            $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $jsonData
            
            Write-Output "Successfully sent data to Azure Monitor."
            Write-Output "Response: $response"
        }
        catch {
            Write-Error "Error sending data to Logs Ingestion API: $_"
            
            # Try to extract more detailed error information
            if ($_.Exception.Response) {
                $statusCode = $_.Exception.Response.StatusCode.value__
                Write-Error "Status code: $statusCode"
                
                try {
                    $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                    $responseBody = $reader.ReadToEnd()
                    $reader.Close()
                    Write-Error "Response body: $responseBody"
                }
                catch {
                    Write-Error "Could not read error response body: $_"
                }
            }
            
            # Try sending a simpler test payload if the main one failed
            Write-Output "Attempting to send a simple test record..."
            $testData = @(
                @{
                    TimeGenerated = [DateTime]::UtcNow.ToString("o")
                    Message = "Test log entry"
                    Source = "CostManagementTest"
                }
            )
            
            # Convert to JSON ensuring it's an array format
            $testJsonData = "[$($testData | ConvertTo-Json -Compress)]"
            
            try {
                $testResponse = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $testJsonData
                Write-Output "Test record sent successfully."
                Write-Output "Response: $testResponse"
            }
            catch {
                Write-Error "Error sending test record: $_"
                if ($_.Exception.Response) {
                    $statusCode = $_.Exception.Response.StatusCode.value__
                    Write-Error "Status code: $statusCode"
                    
                    try {
                        $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                        $responseBody = $reader.ReadToEnd()
                        $reader.Close()
                        Write-Error "Response body: $responseBody"
                    }
                    catch {
                        Write-Error "Could not read error response body: $_"
                    }
                }
            }
            
            throw "Failed to send data to Azure Monitor. See error details above."
        }
    }
    catch {
        Write-Error "Failed to upload data: $_"
        throw
    }
}
else {
    Write-Output "No data to upload"
}

Write-Output "Script execution completed"