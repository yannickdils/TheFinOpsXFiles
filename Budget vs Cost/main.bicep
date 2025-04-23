targetScope = 'subscription'

@description('Location for all resources.')
param location string = 'westeurope'

@description('Tags for all resources')
param tags object = {}

// Resource names
param resourceGroupName string
param automationAccountName string
param logAnalyticsWorkspaceName string
param dcrName string

// Create resource group
resource resourceGroup 'Microsoft.Resources/resourceGroups@2022-09-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

// Deploy resources to the resource group
module resources 'resources.bicep' = {
  name: 'resourcesDeployment'
  scope: resourceGroup
  params: {
    location: location
    automationAccountName: automationAccountName
    logAnalyticsWorkspaceName: logAnalyticsWorkspaceName
    dcrName: dcrName
    tags: tags
  }
}

// Outputs
output resourceGroupName string = resourceGroup.name
output automationAccountName string = automationAccountName
output logAnalyticsWorkspaceName string = logAnalyticsWorkspaceName
output dataCollectionRuleName string = dcrName
output dataCollectionEndpointName string = resources.outputs.dataCollectionEndpointName
output dcrImmutableId string = resources.outputs.dcrImmutableId
output dceEndpoint string = resources.outputs.dceEndpoint
