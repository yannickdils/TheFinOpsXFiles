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
    
    # Initialize management group variables with default values
    $mgmtGroup = "No Data"
    $mgmtGroupPath = "No Data"
    $foundSubscription = $false
    
    # Get management group information for this subscription
    try {
        Write-Output "Getting management group for subscription: $($sub.Name)"
        
        # Method 1: Direct REST API approach using getEntityParents
        try {
            Write-Output "Trying method 1: Direct REST API using getEntityParents..."
            
            $token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com/").Token
            $headers = @{
                "Authorization" = "Bearer $token"
                "Content-Type" = "application/json"
            }
            
            $apiVersion = "2020-02-01"
            $parentUrl = "https://management.azure.com/subscriptions/$($sub.Id)/providers/Microsoft.Management/getEntityParents?api-version=$apiVersion"
            
            $parentResponse = Invoke-RestMethod -Uri $parentUrl -Method Post -Headers $headers -ErrorAction Stop
            
            if ($parentResponse.value -and $parentResponse.value.Count -gt 0) {
                # Extract management group info
                $mgParent = $parentResponse.value | Where-Object { $_.type -eq 'Microsoft.Management/managementGroups' } | Select-Object -First 1
                
                if ($mgParent) {
                    try {
                        # Get more details about the management group
                        $mgDetail = Get-AzManagementGroup -GroupId $mgParent.name -ErrorAction Stop
                        $mgmtGroup = $mgDetail.DisplayName
                        $mgmtGroupPath = $mgDetail.DisplayName
                        $foundSubscription = $true
                        Write-Output "Found management group via REST API (method 1): $mgmtGroup"
                    } catch {
                        # If we can't get the group details, use what we have from the REST API
                        if ($mgParent.properties.displayName) {
                            $mgmtGroup = $mgParent.properties.displayName
                            $mgmtGroupPath = $mgParent.properties.displayName
                            $foundSubscription = $true
                            Write-Output "Found management group via REST API (method 1, using properties): $mgmtGroup"
                        }
                    }
                }
            } else {
                Write-Output "No parent entities found via REST API"
            }
        } catch {
            Write-Output "Method 1 (REST API) failed: $_"
        }
        
        # Method 2: Try with IncludeManagementGroupId parameter if available (for newer Az module versions)
        if (-not $foundSubscription) {
            try {
                Write-Output "Trying method 2: Get-AzSubscription with IncludeManagementGroupId..."
                
                # Check if the parameter exists before trying to use it
                $cmdletInfo = Get-Command Get-AzSubscription -ErrorAction Stop
                $hasIncludeMgParam = $cmdletInfo.Parameters.Keys -contains "IncludeManagementGroupId"
                
                if ($hasIncludeMgParam) {
                    $mgSubscription = Get-AzSubscription -SubscriptionId $sub.Id -IncludeManagementGroupId -ErrorAction Stop
                    
                    if ($mgSubscription.ManagedByTenants -and $mgSubscription.ManagedByTenants.Count -gt 0) {
                        $mgmtGroupId = $mgSubscription.ManagedByTenants[0].TenantId
                        
                        if ($mgmtGroupId) {
                            try {
                                $mgmtGroupDetail = Get-AzManagementGroup -GroupId $mgmtGroupId -ErrorAction Stop
                                if ($mgmtGroupDetail) {
                                    $mgmtGroup = $mgmtGroupDetail.DisplayName
                                    $mgmtGroupPath = $mgmtGroupDetail.DisplayName
                                    $foundSubscription = $true
                                    Write-Output "Found management group (method 2): $mgmtGroup"
                                }
                            } catch {
                                Write-Output "Method 2 error getting management group details: $_"
                            }
                        }
                    }
                } else {
                    Write-Output "IncludeManagementGroupId parameter not available in this Az.Resources version"
                }
            } catch {
                Write-Output "Method 2 failed: $_"
            }
        }
        
        # Method 3: Try searching in all Management Groups
        if (-not $foundSubscription) {
            try {
                Write-Output "Trying method 3: Search in all Management Groups..."
                
                # Get all management groups
                $allGroups = Get-AzManagementGroup -ErrorAction SilentlyContinue
                Write-Output "Retrieved $(($allGroups | Measure-Object).Count) management groups for checking"
                
                # Process each group to find our subscription
                foreach ($group in $allGroups) {
                    try {
                        Write-Output "  Checking management group: $($group.Name) (Display name: $($group.DisplayName))"
                        
                        # Get expanded details with children
                        $expandedGroup = Get-AzManagementGroup -GroupId $group.Name -Expand -ErrorAction SilentlyContinue
                        
                        if ($expandedGroup -and $expandedGroup.Children) {
                            Write-Output "    Group has $($expandedGroup.Children.Count) children"
                            
                            # Check each child object
                            foreach ($child in $expandedGroup.Children) {
                                # Debug information about child type and name
                                Write-Output "    Checking child: Type=$($child.Type), Name=$($child.Name)"
                                
                                # Direct subscription child
                                if ($child.Type -like '*subscriptions' -and $child.Name -eq $sub.Id) {
                                    $mgmtGroup = $expandedGroup.DisplayName
                                    $mgmtGroupPath = $expandedGroup.DisplayName
                                    $foundSubscription = $true
                                    Write-Output "    Found subscription as direct child in management group: $mgmtGroup"
                                    break
                                }
                            }
                            
                            # If found, break out of the groups loop
                            if ($foundSubscription) {
                                break
                            }
                        }
                    } catch {
                        Write-Output "    Error checking management group $($group.Name): $_"
                    }
                }
                
                # Method 3b: Try recursively checking each management group (deeper check)
                if (-not $foundSubscription -and $allGroups -and $allGroups.Count -gt 0) {
                    Write-Output "  Trying deeper recursive check of management groups..."
                    
                    function Find-SubscriptionInGroup {
                        param (
                            [Parameter(Mandatory = $true)]
                            [string]$GroupId,
                            
                            [Parameter(Mandatory = $true)]
                            [string]$SubscriptionId,
                            
                            [Parameter(Mandatory = $false)]
                            [string]$Path = ""
                        )
                        
                        try {
                            # Get details with expansion
                            $grp = Get-AzManagementGroup -GroupId $GroupId -Expand -ErrorAction SilentlyContinue
                            
                            if (-not $grp -or -not $grp.Children) {
                                return $null
                            }
                            
                            # Set current path
                            $currentPath = if ([string]::IsNullOrEmpty($Path)) { 
                                $grp.DisplayName 
                            } else { 
                                "$Path/$($grp.DisplayName)" 
                            }
                            
                            # Check direct children
                            foreach ($child in $grp.Children) {
                                if ($child.Type -like '*subscriptions' -and $child.Name -eq $SubscriptionId) {
                                    return @{
                                        GroupName = $grp.DisplayName
                                        Path = $currentPath
                                    }
                                }
                            }
                            
                            # Check nested groups
                            foreach ($child in $grp.Children) {
                                if ($child.Type -like '*managementGroups') {
                                    $result = Find-SubscriptionInGroup -GroupId $child.Name -SubscriptionId $SubscriptionId -Path $currentPath
                                    if ($result) {
                                        return $result
                                    }
                                }
                            }
                            
                            return $null
                        } catch {
                            Write-Output "      Error in recursive check of group ${GroupId}: ${_}"
                            return $null
                        }
                    }
                    
                    # Try with each top-level management group
                    foreach ($topGroup in $allGroups) {
                        Write-Output "    Recursively checking group: $($topGroup.DisplayName)"
                        $result = Find-SubscriptionInGroup -GroupId $topGroup.Name -SubscriptionId $sub.Id
                        
                        if ($result) {
                            $mgmtGroup = $result.GroupName
                            $mgmtGroupPath = $result.Path
                            $foundSubscription = $true
                            Write-Output "    Found subscription in nested path: $mgmtGroupPath"
                            break
                        }
                    }
                }
            } catch {
                Write-Output "Method 3 failed: $_"
            }
        }
        
        # Method 4: Alternative REST API approach for deeply nested hierarchy
        if (-not $foundSubscription) {
            try {
                Write-Output "Trying method 4: Alternative REST API for management group hierarchy..."
                
                if (-not $token) {
                    $token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com/").Token
                    $headers = @{
                        "Authorization" = "Bearer $token"
                        "Content-Type" = "application/json"
                    }
                }
                
                # Get the tenant ID
                $tenantId = (Get-AzContext).Tenant.Id
                
                # Get the management group hierarchy starting from the root
                $rootUrl = "https://management.azure.com/providers/Microsoft.Management/managementGroups/$tenantId/descendants?api-version=2020-02-01"
                
                $hierarchyResponse = Invoke-RestMethod -Uri $rootUrl -Method Get -Headers $headers -ErrorAction Stop
                
                if ($hierarchyResponse.value) {
                    Write-Output "  Retrieved $($hierarchyResponse.value.Count) management groups in hierarchy"
                    
                    # Function to find the subscription's parent in the hierarchy
                    function Find-SubscriptionParentInHierarchy {
                        param (
                            [Array]$Hierarchy,
                            [string]$SubscriptionId
                        )
                        
                        foreach ($item in $Hierarchy) {
                            # Check if this group has our subscription as a child
                            if ($item.children) {
                                $subChild = $item.children | Where-Object { 
                                    $_.type -eq 'Microsoft.Management/managementGroups/subscriptions' -and 
                                    $_.name -eq $SubscriptionId
                                }
                                
                                if ($subChild) {
                                    return @{
                                        GroupName = $item.properties.displayName
                                        Path = $item.properties.displayName
                                    }
                                }
                                
                                # Recursively check children
                                if ($item.children | Where-Object { $_.type -eq 'Microsoft.Management/managementGroups' }) {
                                    $nestedGroups = $item.children | Where-Object { $_.type -eq 'Microsoft.Management/managementGroups' }
                                    foreach ($nested in $nestedGroups) {
                                        $nestedItems = $Hierarchy | Where-Object { $_.name -eq $nested.name }
                                        foreach ($nestedItem in $nestedItems) {
                                            $result = Find-SubscriptionParentInHierarchy -Hierarchy @($nestedItem) -SubscriptionId $SubscriptionId
                                            if ($result) {
                                                return @{
                                                    GroupName = $result.GroupName
                                                    Path = "$($item.properties.displayName)/$($result.Path)"
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        return $null
                    }
                    
                    $result = Find-SubscriptionParentInHierarchy -Hierarchy $hierarchyResponse.value -SubscriptionId $sub.Id
                    if ($result) {
                        $mgmtGroup = $result.GroupName
                        $mgmtGroupPath = $result.Path
                        $foundSubscription = $true
                        Write-Output "  Found subscription in management group via hierarchy: $mgmtGroupPath"
                    }
                } else {
                    Write-Output "  No management group hierarchy found"
                }
            } catch {
                Write-Output "Method 4 failed: $_"
            }
        }
        
        # Final check - try Management Group API directly for the subscription
        if (-not $foundSubscription) {
            try {
                Write-Output "Trying final method: Direct Management Group API for subscription..."
                
                if (-not $token) {
                    $token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com/").Token
                    $headers = @{
                        "Authorization" = "Bearer $token"
                        "Content-Type" = "application/json"
                    }
                }
                
                # Try to get management group directly for the subscription
                $directUrl = "https://management.azure.com/subscriptions/$($sub.Id)?api-version=2022-12-01"
                
                $subResponse = Invoke-RestMethod -Uri $directUrl -Method Get -Headers $headers -ErrorAction Stop
                
                if ($subResponse.managementGroupId) {
                    $mgId = $subResponse.managementGroupId
                    Write-Output "  Found management group ID from subscription API: $mgId"
                    
                    try {
                        $mgDetail = Get-AzManagementGroup -GroupId $mgId -ErrorAction Stop
                        if ($mgDetail) {
                            $mgmtGroup = $mgDetail.DisplayName
                            $mgmtGroupPath = $mgDetail.DisplayName
                            $foundSubscription = $true
                            Write-Output "  Found management group details: $mgmtGroup"
                        }
                    } catch {
                        Write-Output "  Error getting management group details for ID ${mgId}: $_"
                    }
                } else {
                    Write-Output "  No management group ID found in subscription properties"
                }
            } catch {
                Write-Output "Final method failed: $_"
            }
        }
        
        # Final check if we found anything
        if (-not $foundSubscription) {
            Write-Output "No management group found for this subscription after trying all methods"
        }
    } catch {
        Write-Output "Error retrieving management group (continuing anyway): $_"
    }
    
    try {
        # Get cost for specified period
        Write-Output "Retrieving cost data for the past $DaysToAnalyze days..."
        $startDate = $now.AddDays(-$DaysToAnalyze)
        Write-Output "Date range: $startDate to $now"
        
        $totalCost = 0
        $costRetrievalSuccessful = $false
        
        # Try multiple cost data retrieval methods, starting with the most reliable
        
        # Method 1: Direct REST API approach (works for both CSP and EA)
        if (-not $costRetrievalSuccessful) {
            try {
                Write-Output "Trying cost retrieval method 1: REST API..."
                
                # Get token for ARM
                $token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com/").Token
                $subscriptionId = $sub.Id
                
                # Format dates properly
                $fromDate = $startDate.ToString("yyyy-MM-dd")
                $toDate = $now.ToString("yyyy-MM-dd")
                
                # Build request URL for cost data
                $apiVersion = "2023-03-01"
                $url = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.CostManagement/query?api-version=$apiVersion"
                
                # Build the request body
                $body = @{
                    type = "Usage"
                    timeframe = "Custom"
                    timePeriod = @{
                        from = $fromDate
                        to = $toDate
                    }
                    dataset = @{
                        granularity = "None"
                        aggregation = @{
                            totalCost = @{
                                name = "PreTaxCost"
                                function = "Sum"
                            }
                        }
                    }
                }
                
                # Convert body to JSON
                $bodyJson = $body | ConvertTo-Json -Depth 10
                
                # Set headers
                $headers = @{
                    "Authorization" = "Bearer $token"
                    "Content-Type" = "application/json"
                }
                
                # Make the API call
                $response = Invoke-RestMethod -Uri $url -Method Post -Body $bodyJson -Headers $headers
                
                if ($response.properties.rows -and $response.properties.rows.Count -gt 0) {
                    $totalCost = $response.properties.rows[0][0]
                    Write-Output "Successfully retrieved cost data via REST API: $totalCost"
                    $costRetrievalSuccessful = $true
                } else {
                    Write-Output "No cost data found in REST API response"
                }
            } catch {
                Write-Output "REST API cost retrieval failed: $_"
                if ($_.Exception.Response) {
                    $statusCode = $_.Exception.Response.StatusCode.value__
                    Write-Output "Status code: $statusCode"
                }
            }
        }
        
        # Method 2: Traditional PowerShell cmdlet (works better for EA)
        if (-not $costRetrievalSuccessful) {
            try {
                Write-Output "Trying cost retrieval method 2: PowerShell cmdlet with explicit dates..."
                
                $formattedStartDate = Get-Date $startDate -Format "yyyy-MM-dd"
                $formattedEndDate = Get-Date $now -Format "yyyy-MM-dd"
                
                $costParams = @{
                    StartDate = $formattedStartDate
                    EndDate = $formattedEndDate
                    ErrorAction = "Stop"
                }
                
                $costDetails = Get-AzConsumptionUsageDetail @costParams
                
                if ($costDetails -and $costDetails.Count -gt 0) {
                    $totalCost = $costDetails | Measure-Object -Property PretaxCost -Sum | Select-Object -ExpandProperty Sum
                    Write-Output "Successfully retrieved cost data via PowerShell cmdlet: $totalCost"
                    $costRetrievalSuccessful = $true
                } else {
                    Write-Output "No cost data found using PowerShell cmdlet"
                }
            } catch {
                Write-Output "PowerShell cmdlet cost retrieval failed: $_"
            }
        }
        
        # Method 3: Azure Resource Manager API (another alternative approach)
        if (-not $costRetrievalSuccessful) {
            try {
                Write-Output "Trying cost retrieval method 3: Azure Resource Manager API..."
                
                # Get token for ARM if not already obtained
                if (-not $token) {
                    $token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com/").Token
                    $subscriptionId = $sub.Id
                }
                
                # Different API endpoint and format
                $resourceCostUrl = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.CostManagement/dimensions?api-version=2023-03-01"
                
                # Set headers
                $headers = @{
                    "Authorization" = "Bearer $token"
                    "Content-Type" = "application/json"
                }
                
                # First get dimensions to confirm API access
                $dimensionsResponse = Invoke-RestMethod -Uri $resourceCostUrl -Method Get -Headers $headers
                
                # Then try a simpler query
                $simpleQueryUrl = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Consumption/usageDetails?api-version=2019-10-01&`$filter=properties/usageStart ge '$fromDate' and properties/usageEnd le '$toDate'"
                $usageResponse = Invoke-RestMethod -Uri $simpleQueryUrl -Method Get -Headers $headers
                
                if ($usageResponse.value -and $usageResponse.value.Count -gt 0) {
                    $totalCost = ($usageResponse.value | ForEach-Object { $_.properties.pretaxCost } | Measure-Object -Sum).Sum
                    Write-Output "Successfully retrieved cost data via Resource Manager API: $totalCost"
                    $costRetrievalSuccessful = $true
                } else {
                    Write-Output "No cost data found using Resource Manager API"
                }
            } catch {
                Write-Output "Resource Manager API cost retrieval failed: $_"
                if ($_.Exception.Response) {
                    $statusCode = $_.Exception.Response.StatusCode.value__
                    Write-Output "Status code: $statusCode"
                }
            }
        }
        
        # Method 4: CSP-specific Billing API approach
        if (-not $costRetrievalSuccessful) {
            try {
                Write-Output "Trying cost retrieval method 4: CSP Billing API..."
                
                # Get token for ARM if not already obtained
                if (-not $token) {
                    $token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com/").Token
                    $subscriptionId = $sub.Id
                }
                
                # Set headers if not already set
                if (-not $headers) {
                    $headers = @{
                        "Authorization" = "Bearer $token"
                        "Content-Type" = "application/json"
                    }
                }
                
                # Format dates with time component for billing API
                $fromDate = $startDate.ToString("yyyy-MM-ddTHH:mm:ssZ")
                $toDate = $now.ToString("yyyy-MM-ddTHH:mm:ssZ")
                
                # Build request URL for the Microsoft.Billing API endpoint
                $apiVersion = "2020-05-01"
                $url = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Billing/billingPeriods?api-version=$apiVersion"
                
                Write-Output "Getting billing periods..."
                
                # First get billing periods
                $billingPeriodsResponse = Invoke-RestMethod -Uri $url -Method Get -Headers $headers -ErrorAction Stop
                
                if ($billingPeriodsResponse.value -and $billingPeriodsResponse.value.Count -gt 0) {
                    # Get the most recent billing period
                    $billingPeriod = $billingPeriodsResponse.value | Select-Object -First 1
                    $billingPeriodName = $billingPeriod.name
                    
                    Write-Output "Latest billing period: $billingPeriodName"
                    
                    # Now query usage details for this billing period
                    $usageUrl = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Billing/billingPeriods/$billingPeriodName/providers/Microsoft.Consumption/usageDetails?api-version=2019-10-01"
                    
                    $usageResponse = Invoke-RestMethod -Uri $usageUrl -Method Get -Headers $headers -ErrorAction Stop
                    
                    if ($usageResponse.value -and $usageResponse.value.Count -gt 0) {
                        # Calculate total cost
                        $periodUsage = $usageResponse.value | Where-Object { 
                            $_.properties.usageStart -ge $startDate -and 
                            $_.properties.usageEnd -le $now 
                        }
                        
                        if ($periodUsage) {
                            $totalCost = ($periodUsage | ForEach-Object { 
                                [double]$_.properties.pretaxCost 
                            } | Measure-Object -Sum).Sum
                            
                            Write-Output "Successfully retrieved cost data via Billing API: $totalCost"
                            $costRetrievalSuccessful = $true
                        } else {
                            Write-Output "No matching usage data found in the billing period"
                        }
                    } else {
                        Write-Output "No usage data found in Billing API response"
                    }
                } else {
                    Write-Output "No billing periods found"
                }
            } catch {
                Write-Output "CSP Billing API cost retrieval failed: $_"
                if ($_.Exception.Response) {
                    $statusCode = $_.Exception.Response.StatusCode.value__
                    Write-Output "Status code: $statusCode"
                }
            }
        }
        
        # If all methods failed, use 0 as fallback
        if (-not $costRetrievalSuccessful) {
            Write-Output "All cost retrieval methods failed, using 0 as fallback"
            $totalCost = 0
        }
        
        # Try multiple budget retrieval methods
        $budgetAmount = $null
        $budgetRetrievalSuccessful = $false
        
        # Method 1: REST API for budget (works for both CSP and EA)
        if (-not $budgetRetrievalSuccessful) {
            try {
                Write-Output "Trying budget retrieval using REST API..."
                
                # Get token for ARM if not already obtained
                if (-not $token) {
                    $token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com/").Token
                    $subscriptionId = $sub.Id
                }
                
                # Set headers if not already set
                if (-not $headers) {
                    $headers = @{
                        "Authorization" = "Bearer $token"
                        "Content-Type" = "application/json"
                    }
                }
                
                # Build request URL for budget data
                $budgetUrl = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Consumption/budgets?api-version=2023-03-01"
                
                # Make the API call
                $budgetResponse = Invoke-RestMethod -Uri $budgetUrl -Method Get -Headers $headers
                
                if ($budgetResponse.value -and $budgetResponse.value.Count -gt 0) {
                    $budgetAmount = $budgetResponse.value[0].properties.amount
                    Write-Output "Successfully retrieved budget via REST API: $budgetAmount"
                    $budgetRetrievalSuccessful = $true
                } else {
                    Write-Output "No budget found in REST API response"
                }
            } catch {
                Write-Output "REST API budget retrieval failed: $_"
                if ($_.Exception.Response) {
                    $statusCode = $_.Exception.Response.StatusCode.value__
                    Write-Output "Status code: $statusCode"
                }
            }
        }
        
        # Method 2: Traditional PowerShell cmdlet for budget
        if (-not $budgetRetrievalSuccessful) {
            try {
                Write-Output "Trying budget retrieval using PowerShell cmdlet..."
                
                $budget = Get-AzConsumptionBudget -ErrorAction Stop | Select-Object -First 1
                if ($budget) {
                    $budgetAmount = $budget.Amount
                    Write-Output "Successfully retrieved budget via PowerShell cmdlet: $budgetAmount"
                    $budgetRetrievalSuccessful = $true
                } else {
                    Write-Output "No budget found using PowerShell cmdlet"
                }
            } catch {
                Write-Output "PowerShell cmdlet budget retrieval failed: $_"
            }
        }
        
        # Calculate budget usage
        $budgetUsed = if ($budgetAmount -and $budgetAmount -ne 0) {
            ($totalCost / $budgetAmount) * 100
        } else {
            $null
        }
        
        # Add to output collection
        $costData += [PSCustomObject]@{
            TimeGenerated     = $now.ToUniversalTime()
            Year              = $year
            Month             = $month
            SubscriptionName  = $sub.Name
            SubscriptionId    = $sub.Id
            ManagementGroup   = $mgmtGroup
            ManagementGroupPath = $mgmtGroupPath
            CostAmount        = $totalCost
            BudgetAmount      = $budgetAmount
            BudgetUsedPercent = $budgetUsed
            Currency          = "EUR" # Assuming EUR as currency
            Status            = $sub.State
            PeriodStart       = $startDate.ToString("yyyy-MM-dd")
            PeriodEnd         = $now.ToString("yyyy-MM-dd")
        }
        
        Write-Output "Added cost data for subscription $($sub.Name): Cost = $totalCost EUR, Budget = $budgetAmount EUR, Management Group = $mgmtGroup"
    }
    catch {
        Write-Error "Error processing subscription $($sub.Name): $_"
    }
    
    # Add a small delay between subscriptions to avoid throttling
    Start-Sleep -Seconds 2
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