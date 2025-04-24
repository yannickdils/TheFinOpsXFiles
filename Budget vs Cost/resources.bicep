@description('Location for all resources.')
param location string

@description('Tags for all resources')
param tags object = {}

// Resource names
param automationAccountName string
param logAnalyticsWorkspaceName string
param dcrName string
param dceName string = 'dce-${replace(dcrName, 'dcr-', '')}'

// Role definition IDs
var monitoringMetricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb'

// Automation Account
resource automationAccount 'Microsoft.Automation/automationAccounts@2022-08-08' = {
  name: automationAccountName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Basic'
    }
    encryption: {
      keySource: 'Microsoft.Automation'
    }
    publicNetworkAccess: true
  }
}

// Log Analytics Workspace
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    workspaceCapping: {
      dailyQuotaGb: 1
    }
  }
}

// Create custom log table (V2-compatible)
resource customTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: logAnalyticsWorkspace
  name: 'CostManagementData_CL'
  properties: {
    schema: {
      name: 'CostManagementData_CL'
      columns: [
        {
          name: 'TimeGenerated'
          type: 'datetime'
        }
        {
          name: 'Year'
          type: 'int'
        }
        {
          name: 'Month'
          type: 'string'
        }
        {
          name: 'ManagementGroup'
          type: 'string'
        }
        {
          name: 'ManagementGroupPath'
          type: 'string'
        }
        {
          name: 'SubscriptionName'
          type: 'string'
        }
        {
          name: 'SubscriptionId'
          type: 'string'
        }
        {
          name: 'CostAmount'
          type: 'real'
        }
        {
          name: 'BudgetAmount'
          type: 'real'
        }
        {
          name: 'BudgetUsedPercent'
          type: 'real'
        }
        {
          name: 'Currency'
          type: 'string'
        }
        {
          name: 'Status'
          type: 'string'
        }
        {
          name: 'PeriodStart'
          type: 'string'
        }
        {
          name: 'PeriodEnd'
          type: 'string'
        }
      ]
    }
  }
}

// Data Collection Endpoint (DCE)
resource dce 'Microsoft.Insights/dataCollectionEndpoints@2021-09-01-preview' = {
  name: dceName
  location: location
  tags: tags
  kind: 'Linux' // This works for both Windows and Linux
  properties: {}
}

// Data Collection Rule
resource dcr 'Microsoft.Insights/dataCollectionRules@2021-09-01-preview' = {
  name: dcrName
  location: location
  tags: tags
  properties: {
    dataCollectionEndpointId: dce.id
    dataSources: {}
    destinations: {
      logAnalytics: [
        {
          name: 'la-destination'
          workspaceResourceId: logAnalyticsWorkspace.id
        }
      ]
    }
    dataFlows: [
      {
        streams: ['Custom-CostManagementData_CL']
        destinations: ['la-destination']
      }
    ]
  }
}

// Create Automation Variables for DCE and DCR
resource dceEndpointVariable 'Microsoft.Automation/automationAccounts/variables@2022-08-08' = {
  parent: automationAccount
  name: 'dceEndpoint'
  properties: {
    description: 'Data Collection Endpoint URL for the FinOps solution'
    value: '"${dce.properties.logsIngestion.endpoint}"'
    isEncrypted: false
  }
}

resource dcrImmutableIdVariable 'Microsoft.Automation/automationAccounts/variables@2022-08-08' = {
  parent: automationAccount
  name: 'dcrImmutableId'
  properties: {
    description: 'Immutable ID of the Data Collection Rule for the FinOps solution'
    value: '"${dcr.properties.immutableId}"'
    isEncrypted: false
  }
}

resource tableNameVariable 'Microsoft.Automation/automationAccounts/variables@2022-08-08' = {
  parent: automationAccount
  name: 'tableName'
  properties: {
    description: 'Custom Log Analytics table name for the FinOps solution'
    value: '"CostManagementData_CL"'
    isEncrypted: false
  }
}

// Role assignment for DCR - Allow system-assigned identity to publish metrics
resource dcrRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, automationAccount.id, dcr.id, 'Monitoring Metrics Publisher')
  scope: dcr
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      monitoringMetricsPublisherRoleId
    )
    principalId: automationAccount.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Role assignment for DCE - Allow system-assigned identity to publish data
resource dceRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, automationAccount.id, dce.id, 'Monitoring Metrics Publisher')
  scope: dce
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      monitoringMetricsPublisherRoleId
    )
    principalId: automationAccount.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Outputs
output automationAccountName string = automationAccount.name
output logAnalyticsWorkspaceName string = logAnalyticsWorkspace.name
output dataCollectionRuleName string = dcr.name
output dataCollectionEndpointName string = dce.name
output dcrImmutableId string = dcr.properties.immutableId
output dceEndpoint string = dce.properties.logsIngestion.endpoint
