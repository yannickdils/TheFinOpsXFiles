#Requires -Modules Az.Resources
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $true)]
    [string]$AutomationAccountName,
    
    [Parameter(Mandatory = $false)]
    [string]$LogAnalyticsWorkspaceName = "",
    
    [Parameter(Mandatory = $false)]
    [string]$DataCollectionRuleName = "",
    
    [Parameter(Mandatory = $false)]
    [string]$DataCollectionEndpointName = ""
)

Write-Host "Configuring permissions..." -ForegroundColor Cyan

# Get the automation account and its system-assigned identity
try {
    $automationAccount = Get-AzAutomationAccount -ResourceGroupName $ResourceGroupName -Name $AutomationAccountName
    if (-not $automationAccount) {
        Write-Error "Automation Account '$AutomationAccountName' not found in resource group '$ResourceGroupName'"
        exit 1
    }
    
    $systemIdentityPrincipalId = $automationAccount.Identity.PrincipalId
    
    if (-not $systemIdentityPrincipalId) {
        Write-Error "System-assigned identity is not enabled on the Automation Account '$AutomationAccountName'"
        exit 1
    }
    
    Write-Host "Found Automation Account with system-assigned identity: $($systemIdentityPrincipalId)" -ForegroundColor Green
} catch {
    Write-Error "Error retrieving Automation Account details: $_"
    exit 1
}

# Get all available subscriptions
Write-Host "Getting all available subscriptions..." -ForegroundColor Cyan
$subscriptions = Get-AzSubscription
Write-Host "Found $($subscriptions.Count) subscriptions" -ForegroundColor Green

# Save current context
$originalContext = Get-AzContext

# First, find the Log Analytics workspace
$workspace = $null

# If a specific workspace name was provided
if (-not [string]::IsNullOrEmpty($LogAnalyticsWorkspaceName)) {
    Write-Host "Looking for specified Log Analytics workspace: $LogAnalyticsWorkspaceName..." -ForegroundColor Cyan
    
    # Try to find the workspace in the same resource group as the Automation Account first
    $workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $LogAnalyticsWorkspaceName -ErrorAction SilentlyContinue
    
    if ($workspace) {
        Write-Host "Found Log Analytics workspace in resource group $ResourceGroupName" -ForegroundColor Green
    } else {
        # If not found, search through all subscriptions
        foreach ($subscription in $subscriptions) {
            Write-Host "  Looking in subscription: $($subscription.Name)..." -ForegroundColor Yellow
            Set-AzContext -SubscriptionId $subscription.Id | Out-Null
            
            $workspace = Get-AzOperationalInsightsWorkspace -Name $LogAnalyticsWorkspaceName -ErrorAction SilentlyContinue
            
            if ($workspace) {
                Write-Host "  Found workspace in subscription: $($subscription.Name)" -ForegroundColor Green
                break
            }
        }
    }
}

# Set context to the subscription containing the workspace
if ($workspace) {
    $workspaceSubscriptionContext = Set-AzContext -SubscriptionId $workspace.ResourceId.Split('/')[2]
    
    Write-Host "Assigning roles to Log Analytics workspace: $($workspace.Name)" -ForegroundColor Cyan
    
    # Assign Log Analytics Contributor role
    try {
        $existingLAContributorRole = Get-AzRoleAssignment -ObjectId $systemIdentityPrincipalId `
                                                         -RoleDefinitionName "Log Analytics Contributor" `
                                                         -Scope $workspace.ResourceId `
                                                         -ErrorAction SilentlyContinue
        
        if (-not $existingLAContributorRole) {
            Write-Host "  Assigning Log Analytics Contributor role..." -ForegroundColor Yellow
            New-AzRoleAssignment -ObjectId $systemIdentityPrincipalId `
                                -RoleDefinitionName "Log Analytics Contributor" `
                                -Scope $workspace.ResourceId | Out-Null
            
            Write-Host "  Log Analytics Contributor role assigned successfully" -ForegroundColor Green
        } else {
            Write-Host "  Log Analytics Contributor role is already assigned" -ForegroundColor Yellow
        }
        
        # Also assign Reader role if not already assigned
        $existingReaderRole = Get-AzRoleAssignment -ObjectId $systemIdentityPrincipalId `
                                                  -RoleDefinitionName "Reader" `
                                                  -Scope $workspace.ResourceId `
                                                  -ErrorAction SilentlyContinue
        
        if (-not $existingReaderRole) {
            Write-Host "  Assigning Reader role to workspace..." -ForegroundColor Yellow
            New-AzRoleAssignment -ObjectId $systemIdentityPrincipalId `
                                -RoleDefinitionName "Reader" `
                                -Scope $workspace.ResourceId | Out-Null
            
            Write-Host "  Reader role assigned successfully" -ForegroundColor Green
        } else {
            Write-Host "  Reader role is already assigned" -ForegroundColor Yellow
        }
    } catch {
        Write-Error "  Error assigning workspace roles: $_"
    }
    
    # If a Data Collection Rule name was provided, find it and assign roles
    if (-not [string]::IsNullOrEmpty($DataCollectionRuleName)) {
        Write-Host "Looking for Data Collection Rule: $DataCollectionRuleName..." -ForegroundColor Cyan
        
        # Find the DCR in the workspace's resource group first
        $dcr = Get-AzDataCollectionRule -ResourceGroupName $workspace.ResourceGroupName -Name $DataCollectionRuleName -ErrorAction SilentlyContinue
        
        if (-not $dcr) {
            # Try to find it in other resource groups in the current subscription
            $dcr = Get-AzDataCollectionRule -Name $DataCollectionRuleName -ErrorAction SilentlyContinue
        }
        
        if ($dcr) {
            Write-Host "Found Data Collection Rule: $($dcr.Name)" -ForegroundColor Green
            
            # Assign Monitoring Metrics Publisher role to the DCR
            try {
                $existingMetricsPublisherRole = Get-AzRoleAssignment -ObjectId $systemIdentityPrincipalId `
                                                                   -RoleDefinitionName "Monitoring Metrics Publisher" `
                                                                   -Scope $dcr.Id `
                                                                   -ErrorAction SilentlyContinue
                
                if (-not $existingMetricsPublisherRole) {
                    Write-Host "  Assigning Monitoring Metrics Publisher role to DCR..." -ForegroundColor Yellow
                    New-AzRoleAssignment -ObjectId $systemIdentityPrincipalId `
                                        -RoleDefinitionName "Monitoring Metrics Publisher" `
                                        -Scope $dcr.Id | Out-Null
                    
                    Write-Host "  Monitoring Metrics Publisher role assigned successfully" -ForegroundColor Green
                } else {
                    Write-Host "  Monitoring Metrics Publisher role is already assigned" -ForegroundColor Yellow
                }
            } catch {
                Write-Error "  Error assigning DCR roles: $_"
            }
        } else {
            Write-Host "Could not find Data Collection Rule: $DataCollectionRuleName" -ForegroundColor Yellow
        }
    }
    
    # If a Data Collection Endpoint name was provided, find it and assign roles
    if (-not [string]::IsNullOrEmpty($DataCollectionEndpointName)) {
        Write-Host "Looking for Data Collection Endpoint: $DataCollectionEndpointName..." -ForegroundColor Cyan
        
        # Find the DCE in the workspace's resource group first
        $dce = Get-AzDataCollectionEndpoint -ResourceGroupName $workspace.ResourceGroupName -Name $DataCollectionEndpointName -ErrorAction SilentlyContinue
        
        if (-not $dce) {
            # Try to find it in other resource groups in the current subscription
            $dce = Get-AzDataCollectionEndpoint -Name $DataCollectionEndpointName -ErrorAction SilentlyContinue
        }
        
        if ($dce) {
            Write-Host "Found Data Collection Endpoint: $($dce.Name)" -ForegroundColor Green
            
            # Assign Monitoring Metrics Publisher role to the DCE
            try {
                $existingMetricsPublisherRole = Get-AzRoleAssignment -ObjectId $systemIdentityPrincipalId `
                                                                   -RoleDefinitionName "Monitoring Metrics Publisher" `
                                                                   -Scope $dce.Id `
                                                                   -ErrorAction SilentlyContinue
                
                if (-not $existingMetricsPublisherRole) {
                    Write-Host "  Assigning Monitoring Metrics Publisher role to DCE..." -ForegroundColor Yellow
                    New-AzRoleAssignment -ObjectId $systemIdentityPrincipalId `
                                        -RoleDefinitionName "Monitoring Metrics Publisher" `
                                        -Scope $dce.Id | Out-Null
                    
                    Write-Host "  Monitoring Metrics Publisher role assigned successfully" -ForegroundColor Green
                } else {
                    Write-Host "  Monitoring Metrics Publisher role is already assigned" -ForegroundColor Yellow
                }
            } catch {
                Write-Error "  Error assigning DCE roles: $_"
            }
        } else {
            Write-Host "Could not find Data Collection Endpoint: $DataCollectionEndpointName" -ForegroundColor Yellow
        }
    }
}

# Get the tenant ID from the current context
$tenantId = (Get-AzContext).Tenant.Id

# Assign Management Group Reader role at tenant level
Write-Host "Attempting to assign Management Group Reader role at tenant root level..." -ForegroundColor Cyan
$mgmtGroupReaderAssigned = $false

try {
    # Check if role is already assigned at tenant level
    $existingMgmtGroupReaderRole = Get-AzRoleAssignment -ObjectId $systemIdentityPrincipalId `
                                                       -RoleDefinitionName "Management Group Reader" `
                                                       -Scope "/providers/Microsoft.Management/managementGroups/$tenantId" `
                                                       -ErrorAction SilentlyContinue
    
    if (-not $existingMgmtGroupReaderRole) {
        # Create new role assignment at tenant root level
        Write-Host "  Assigning Management Group Reader role at tenant root level..." -ForegroundColor Yellow
        New-AzRoleAssignment -ObjectId $systemIdentityPrincipalId `
                            -RoleDefinitionName "Management Group Reader" `
                            -Scope "/providers/Microsoft.Management/managementGroups/$tenantId" | Out-Null
        
        Write-Host "  Management Group Reader role assigned successfully at tenant level" -ForegroundColor Green
        $mgmtGroupReaderAssigned = $true
    } else {
        Write-Host "  Management Group Reader role is already assigned at tenant level" -ForegroundColor Yellow
        $mgmtGroupReaderAssigned = $true
    }
} catch {
    Write-Host "  Could not assign Management Group Reader role at tenant level: $_" -ForegroundColor Yellow
    Write-Host "  The script will continue, but management group detection in the runbook might be limited." -ForegroundColor Yellow
}

# Try to assign Cost Management Reader role at tenant root level first
Write-Host "Attempting to assign Cost Management Reader role at tenant root level..." -ForegroundColor Cyan
$tenantRoleAssignmentSuccess = $false

try {
    # Check if role is already assigned at tenant level
    $existingRoleAssignment = Get-AzRoleAssignment -ObjectId $systemIdentityPrincipalId `
                                                  -RoleDefinitionName "Cost Management Reader" `
                                                  -Scope "/providers/Microsoft.Management/managementGroups/$tenantId" `
                                                  -ErrorAction SilentlyContinue
    
    if (-not $existingRoleAssignment) {
        # Create new role assignment at tenant root level
        Write-Host "  Assigning Cost Management Reader role at tenant root level..." -ForegroundColor Yellow
        New-AzRoleAssignment -ObjectId $systemIdentityPrincipalId `
                            -RoleDefinitionName "Cost Management Reader" `
                            -Scope "/providers/Microsoft.Management/managementGroups/$tenantId" | Out-Null
        
        Write-Host "  Cost Management Reader role assigned successfully at tenant level" -ForegroundColor Green
        $tenantRoleAssignmentSuccess = $true
    } else {
        Write-Host "  Cost Management Reader role is already assigned at tenant level" -ForegroundColor Yellow
        $tenantRoleAssignmentSuccess = $true
    }
} catch {
    Write-Host "  Could not assign Cost Management Reader role at tenant level: $_" -ForegroundColor Yellow
    Write-Host "  Will fall back to subscription-level assignments..." -ForegroundColor Yellow
}

# If tenant-level assignment failed, fall back to subscription-by-subscription assignment
if (-not $tenantRoleAssignmentSuccess) {
    Write-Host "Falling back to subscription-level role assignments..." -ForegroundColor Cyan
    
    # Loop through each subscription and assign Cost Management Reader role
    foreach ($subscription in $subscriptions) {
        Write-Host "Processing subscription: $($subscription.Name) ($($subscription.Id))" -ForegroundColor Cyan
        
        # Set context to current subscription
        Set-AzContext -SubscriptionId $subscription.Id | Out-Null
        
        # Assign Cost Management Reader role at subscription level to system-assigned identity
        try {
            # Check if role is already assigned
            $existingRoleAssignment = Get-AzRoleAssignment -ObjectId $systemIdentityPrincipalId -RoleDefinitionName "Cost Management Reader" -Scope "/subscriptions/$($subscription.Id)" -ErrorAction SilentlyContinue
            
            if (-not $existingRoleAssignment) {
                # Create new role assignment
                Write-Host "  Assigning Cost Management Reader role..." -ForegroundColor Yellow
                New-AzRoleAssignment -ObjectId $systemIdentityPrincipalId `
                                    -RoleDefinitionName "Cost Management Reader" `
                                    -Scope "/subscriptions/$($subscription.Id)" | Out-Null
                
                Write-Host "  Cost Management Reader role assigned successfully" -ForegroundColor Green
            } else {
                Write-Host "  Cost Management Reader role is already assigned" -ForegroundColor Yellow
            }
        } catch {
            Write-Error "  Error assigning Cost Management Reader role in subscription $($subscription.Name): $_"
            Write-Host "  Warning: The system-assigned identity won't have access to cost data for this subscription." -ForegroundColor Yellow
        }
    }
}

# Restore original context
Set-AzContext -Context $originalContext | Out-Null

Write-Host "Role assignment configuration completed!" -ForegroundColor Green
Write-Host "The system-assigned identity now has:" -ForegroundColor Cyan
if ($mgmtGroupReaderAssigned) {
    Write-Host "  - Management Group Reader role at the tenant root level" -ForegroundColor Cyan
} else {
    Write-Host "  - Limited management group visibility (Management Group Reader role could not be assigned)" -ForegroundColor Yellow
}
if ($tenantRoleAssignmentSuccess) {
    Write-Host "  - Cost Management Reader role at the tenant root level (inherited by all subscriptions)" -ForegroundColor Cyan
} else {
    Write-Host "  - Cost Management Reader role on individual subscriptions" -ForegroundColor Cyan
}
if ($workspace) {
    Write-Host "  - Log Analytics Contributor and Reader roles on workspace: $($workspace.Name)" -ForegroundColor Cyan
}
if ($dcr) {
    Write-Host "  - Monitoring Metrics Publisher role on DCR: $($dcr.Name)" -ForegroundColor Cyan
}
if ($dce) {
    Write-Host "  - Monitoring Metrics Publisher role on DCE: $($dce.Name)" -ForegroundColor Cyan
}