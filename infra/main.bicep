targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the the environment which is used to generate a short unique hash used in all resources.')
param environmentName string

@minLength(1)
@description('Primary location for all resources')
@allowed(['australiaeast', 'centralus', 'eastasia','eastus2', 'northeurope', 'southeastasia', 'swedencentral', 'uksouth', 'westus2'])
@metadata({
  azd: {
    type: 'location'
  }
})
param location string

param processorServiceName string = ''
param processorUserAssignedIdentityName string = ''
param applicationInsightsName string = ''
param appServicePlanName string = ''
param logAnalyticsName string = ''
param resourceGroupName string = ''
param storageAccountName string = ''
param vNetName string = ''
param disableLocalAuth bool = true
param dtsName string = ''
param taskHubName string = ''
param dtsLocation string = location
param dtsSkuName string = 'Consumption'
param dtsCapacity int = 1
@description('Id of the user identity to be used for testing and debugging. This is not required in production. Leave empty if not needed.')
param principalId string = deployer().objectId

var abbrs = loadJsonContent('./abbreviations.json')
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var tags = { 'azd-env-name': environmentName }
var dtsResourceName = !empty(dtsName) ? dtsName : '${abbrs.durableTaskSchedulers}${resourceToken}'
var taskHubResourceName = !empty(taskHubName) ? taskHubName : '${abbrs.durableTaskHubs}${resourceToken}'

// Organize resources in a resource group
resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: !empty(resourceGroupName) ? resourceGroupName : '${abbrs.resourcesResourceGroups}${environmentName}'
  location: location
  tags: tags
}

// User assigned managed identity to be used by the Function App to reach storage and service bus
module processorUserAssignedIdentity './core/identity/userAssignedIdentity.bicep' = {
  name: 'processorUserAssignedIdentity'
  scope: rg
  params: {
    location: location
    tags: tags
    identityName: !empty(processorUserAssignedIdentityName) ? processorUserAssignedIdentityName : '${abbrs.managedIdentityUserAssignedIdentities}processor-${resourceToken}'
  }
}

// The application backend
module processor './app/processor.bicep' = {
  name: 'processor'
  scope: rg
  params: {
    name: !empty(processorServiceName) ? processorServiceName : '${abbrs.webSitesFunctions}processor-${resourceToken}'
    location: location
    tags: tags
    applicationInsightsName: monitoring.outputs.applicationInsightsName
    appServicePlanId: appServicePlan.outputs.id
    runtimeName: 'dotnet-isolated'
    runtimeVersion: '10.0'
    storageAccountName: storage.outputs.name
    identityId: processorUserAssignedIdentity.outputs.identityId
    identityClientId: processorUserAssignedIdentity.outputs.identityClientId
    appSettings: {
    }
    virtualNetworkSubnetId: serviceVirtualNetwork.outputs.appSubnetID
    dtsURL: dts.outputs.dts_URL
    taskHubName: dts.outputs.TASKHUB_NAME
  }
}

// Backing storage for Azure functions processor
module storage './core/storage/storage-account.bicep' = {
  name: 'storage'
  scope: rg
  params: {
    name: !empty(storageAccountName) ? storageAccountName : '${abbrs.storageStorageAccounts}${resourceToken}'
    location: location
    tags: tags
    containers: [{name: 'deploymentpackage'}]
    publicNetworkAccess: 'Disabled'
  }
}

var storageRoleDefinitionId  = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b' //Storage Blob Data Owner role
var tableContributorRoleDefinitionId  = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3' //Storage Table Data Contributor role
var blobContributorRoleDefinitionId  = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe' //Storage Blob Data Contributor role
var queueContributorRoleDefinitionId  = '974c5e8b-45b9-4653-ba55-5f855dd0fb88' //Storage Queue Data Contributor role

// Allow access from processor to storage account using a managed identity
module storageRoleAssignmentApi 'app/storage-Access.bicep' = {
  name: 'storageRoleAssignmentPRocessor'
  scope: rg
  params: {
    storageAccountName: storage.outputs.name
    roleDefinitionID: storageRoleDefinitionId
    principalID: processorUserAssignedIdentity.outputs.identityPrincipalId
  }
}

module tableContributorRoleAssignmentApi 'app/storage-Access.bicep' = {
  name: 'tableRoleAssignmentProcessor'
  scope: rg
  params: {
    storageAccountName: storage.outputs.name
    roleDefinitionID: tableContributorRoleDefinitionId
    principalID: processorUserAssignedIdentity.outputs.identityPrincipalId
  }
}

module blobContributorRoleAssignmentApi 'app/storage-Access.bicep' = {
  name: 'blobRoleAssignmentProcessor'
  scope: rg
  params: {
    storageAccountName: storage.outputs.name
    roleDefinitionID: blobContributorRoleDefinitionId
    principalID: processorUserAssignedIdentity.outputs.identityPrincipalId
  }
}

module queueContributorRoleAssignmentApi 'app/storage-Access.bicep' = {
  name: 'queueRoleAssignmentProcessor'
  scope: rg
  params: {
    storageAccountName: storage.outputs.name
    roleDefinitionID: queueContributorRoleDefinitionId
    principalID: processorUserAssignedIdentity.outputs.identityPrincipalId
  }
}


module appServicePlan './core/host/appserviceplan.bicep' = {
  name: 'appserviceplan'
  scope: rg
  params: {
    name: !empty(appServicePlanName) ? appServicePlanName : '${abbrs.webServerFarms}${resourceToken}'
    location: location
    tags: tags
    sku: {
      name: 'FC1'
      tier: 'FlexConsumption'
    }
  }
}

// Virtual Network & private endpoint
module serviceVirtualNetwork 'app/vnet.bicep' = {
  name: 'serviceVirtualNetwork'
  scope: rg
  params: {
    location: location
    tags: tags
    vNetName: !empty(vNetName) ? vNetName : '${abbrs.networkVirtualNetworks}${resourceToken}'
  }
}

module servicePrivateEndpoint 'app/storage-PrivateEndpoint.bicep' = {
  name: 'servicePrivateEndpoint'
  scope: rg
  params: {
    location: location
    tags: tags
    virtualNetworkName: !empty(vNetName) ? vNetName : '${abbrs.networkVirtualNetworks}${resourceToken}'
    subnetName: serviceVirtualNetwork.outputs.peSubnetName
    resourceName: storage.outputs.name
  }
}

// Monitor application with Azure Monitor
module monitoring './core/monitor/monitoring.bicep' = {
  name: 'monitoring'
  scope: rg
  params: {
    location: location
    tags: tags
    logAnalyticsName: !empty(logAnalyticsName) ? logAnalyticsName : '${abbrs.operationalInsightsWorkspaces}${resourceToken}'
    applicationInsightsName: !empty(applicationInsightsName) ? applicationInsightsName : '${abbrs.insightsComponents}${resourceToken}'
    disableLocalAuth: disableLocalAuth  
  }
}

var monitoringRoleDefinitionId = '3913510d-42f4-4e42-8a64-420c390055eb' // Monitoring Metrics Publisher role ID

// Allow access from processor to application insights using a managed identity
module appInsightsRoleAssignmentApi './core/monitor/appinsights-access.bicep' = {
  name: 'appInsightsRoleAssignmentPRocessor'
  scope: rg
  params: {
    appInsightsName: monitoring.outputs.applicationInsightsName
    roleDefinitionID: monitoringRoleDefinitionId
    principalID: processorUserAssignedIdentity.outputs.identityPrincipalId
  }
}

// Durable Task Scheduler
module dts './app/dts.bicep' = {
  scope: rg
  name: 'dtsResource'
  params: {
    name: dtsResourceName
    taskhubname: taskHubResourceName
    location: dtsLocation
    tags: tags
    ipAllowlist: [
      '0.0.0.0/0'
    ]
    skuName: dtsSkuName
    skuCapacity: dtsCapacity
  }
}

// Durable Task Data Contributor role ID
var dtsRoleDefinitionId = '0ad04412-c4d5-4796-b79c-f76d14c8d402'

// Allow access from function app to DTS using user assigned managed identity
module dtsRoleAssignment 'app/dts-Access.bicep' = {
  name: 'dtsRoleAssignment'
  scope: rg
  params: {
    roleDefinitionID: dtsRoleDefinitionId
    principalID: processorUserAssignedIdentity.outputs.identityPrincipalId
    principalType: 'ServicePrincipal'
    dtsName: dts.outputs.dts_NAME
  }
}

// Allow the deployer identity to access the DTS dashboard
module dtsDashboardRoleAssignment 'app/dts-Access.bicep' = {
  name: 'dtsDashboardRoleAssignment'
  scope: rg
  params: {
    roleDefinitionID: dtsRoleDefinitionId
    principalID: principalId
    principalType: 'User'
    dtsName: dts.outputs.dts_NAME
  }
}

// App outputs
output AZURE_LOCATION string = location
output AZURE_TENANT_ID string = tenant().tenantId
output SERVICE_PROCESSOR_NAME string = processor.outputs.SERVICE_PROCESSOR_NAME
output AZURE_FUNCTION_NAME string = processor.outputs.SERVICE_PROCESSOR_NAME
