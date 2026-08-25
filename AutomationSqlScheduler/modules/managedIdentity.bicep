// User Assigned Managed Identity used by the Automation Account runbook
// to authenticate to Azure SQL via Entra ID (no secrets/passwords involved).
@description('Name of the User Assigned Managed Identity to create.')
param uamiName string

@description('Azure region for the identity.')
param location string

@description('Tags to apply to the identity.')
param tags object = {}

resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: uamiName
  location: location
  tags: tags
}

@description('Resource ID of the created User Assigned Managed Identity.')
output id string = uami.id

@description('Principal (object) ID of the identity in Microsoft Entra ID.')
output principalId string = uami.properties.principalId

@description('Client (application) ID of the identity, used by Connect-AzAccount -Identity -AccountId.')
output clientId string = uami.properties.clientId

@description('Tenant ID associated with the identity.')
output tenantId string = uami.properties.tenantId

output name string = uami.name
