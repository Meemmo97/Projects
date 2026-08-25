// Azure Automation Account with a modern PowerShell runtime environment and a
// PowerShell runbook shell (content is published out-of-band by deploy.ps1,
// because the ARM/Bicep resource provider does not accept inline runbook
// script content).
@description('Name of the Automation Account.')
param automationAccountName string

@description('Azure region for the Automation Account.')
param location string

@description('Automation Account SKU name.')
@allowed([
  'Free'
  'Basic'
])
param automationSkuName string = 'Basic'

@description('Tags applied to the Automation Account and child resources.')
param tags object = {}

@description('Resource ID of the User Assigned Managed Identity to attach to the Automation Account.')
param userAssignedIdentityId string

@description('Name of the PowerShell runtime environment (must match ^[a-zA-Z][a-zA-Z-_0-9]*$).')
param runtimeEnvironmentName string = 'PowerShell74'

@description('Runtime language for the runtime environment.')
param runtimeLanguage string = 'PowerShell'

@description('Runtime language version. PowerShell 7.4 is the current GA runtime supported by Azure Automation Runtime Environments.')
param runtimeVersion string = '7.4'

@description('Version of the explicitly imported Az.Accounts package.')
param azAccountsPackageVersion string = '4.2.0'

@description('URI of the Az.Accounts package artifact. Keep the URI and version aligned.')
param azAccountsPackageUri string = 'https://www.powershellgallery.com/api/v2/package/Az.Accounts/4.2.0'

@description('Name of the PowerShell runbook.')
param runbookName string

@description('Description shown on the runbook.')
param runbookDescription string = 'Invokes a configured SQL stored procedure using the Automation Account User Assigned Managed Identity and Entra ID authentication.'

@description('Fully qualified DNS name of the existing Azure SQL logical server.')
param sqlServerFqdn string

@description('Name of the existing Azure SQL database.')
param sqlDatabaseName string

@description('Stored procedure identifier in procedure or schema.procedure format.')
param storedProcedureName string

@description('Client ID of the User Assigned Managed Identity.')
param uamiClientId string

resource automationAccount 'Microsoft.Automation/automationAccounts@2024-10-23' = {
  name: automationAccountName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentityId}': {}
    }
  }
  properties: {
    disableLocalAuth: true
    sku: {
      name: automationSkuName
    }
    publicNetworkAccess: true
  }
}

resource runtimeEnvironment 'Microsoft.Automation/automationAccounts/runtimeEnvironments@2024-10-23' = {
  parent: automationAccount
  name: runtimeEnvironmentName
  location: location
  tags: tags
  properties: {
    runtime: {
      language: runtimeLanguage
      version: runtimeVersion
    }
    description: 'PowerShell ${runtimeVersion} runtime environment used to run the SQL scheduler runbook.'
  }
}

resource azAccountsPackage 'Microsoft.Automation/automationAccounts/runtimeEnvironments/packages@2024-10-23' = {
  parent: runtimeEnvironment
  name: 'Az.Accounts'
  properties: {
    contentLink: {
      uri: azAccountsPackageUri
      version: azAccountsPackageVersion
    }
  }
}

var runbookVariables = [
  {
    name: 'SqlServerFqdn'
    description: 'Fully qualified DNS name of the target Azure SQL logical server.'
    value: sqlServerFqdn
  }
  {
    name: 'SqlDatabaseName'
    description: 'Name of the target Azure SQL database.'
    value: sqlDatabaseName
  }
  {
    name: 'StoredProcedureName'
    description: 'Stored procedure invoked by the runbook; validated at runtime as procedure or schema.procedure.'
    value: storedProcedureName
  }
  {
    name: 'UamiClientId'
    description: 'Client ID of the User Assigned Managed Identity used for Azure SQL authentication.'
    value: uamiClientId
  }
]

resource runbookVariable 'Microsoft.Automation/automationAccounts/variables@2024-10-23' = [for item in runbookVariables: {
  parent: automationAccount
  name: item.name
  properties: {
    description: item.description
    isEncrypted: false
    value: item.value
  }
}]

// The runbook is created empty (draft only) on the first deployment pass.
// deploy.ps1 uploads/publishes the local .ps1 file content via Azure CLI/REST
// after this Bicep deployment completes, then a second Bicep pass can flip
// enableJobSchedule to true once content is published.
resource runbook 'Microsoft.Automation/automationAccounts/runbooks@2024-10-23' = {
  parent: automationAccount
  name: runbookName
  location: location
  tags: tags
  properties: {
    runbookType: 'PowerShell'
    runtimeEnvironment: runtimeEnvironment.name
    description: runbookDescription
    logProgress: true
    logVerbose: false
  }
  dependsOn: [
    azAccountsPackage
    runbookVariable
  ]
}

@description('Resource ID of the Automation Account.')
output id string = automationAccount.id

@description('Name of the Automation Account.')
output name string = automationAccount.name

@description('Name of the created runbook.')
output runbookName string = runbook.name

@description('Name of the runtime environment.')
output runtimeEnvironmentName string = runtimeEnvironment.name

@description('Version of Az.Accounts explicitly imported into the runtime environment.')
output azAccountsPackageVersion string = azAccountsPackageVersion
