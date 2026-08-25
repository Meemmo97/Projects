// =============================================================================
// AutomationSqlScheduler - main.bicep
// Resource-group scoped template that provisions:
//   - A User Assigned Managed Identity (new)
//   - An Azure Automation Account (with the UAMI attached) + PS7.4 runtime
//     environment + an (initially empty) PowerShell runbook shell
//   - An Automation schedule + optional job-schedule link
//   - An optional "Allow Azure services" firewall rule on an EXISTING Azure
//     SQL logical server
//
// The Azure SQL logical server & database themselves are NOT created here —
// they must already exist (see parameters below).
//
// Runbook script CONTENT is intentionally not embedded here: the Automation
// runbooks ARM/Bicep resource provider does not accept inline script content,
// so publishing is done by deploy.ps1 in a second phase using Azure CLI/REST
// against the local runbooks/Invoke-SqlStoredProcedure.ps1 file.
// =============================================================================

targetScope = 'resourceGroup'

@description('Azure region for all new resources (Automation Account, UAMI). The existing SQL server can be in a different region.')
param location string = resourceGroup().location

@description('Tags applied to all created resources.')
param tags object = {}

// ---------------------------------------------------------------------------
// Naming
// ---------------------------------------------------------------------------
@description('Name of the new User Assigned Managed Identity.')
param uamiName string

@description('Name of the Azure Automation Account to create.')
param automationAccountName string

@description('Automation Account SKU.')
@allowed([
  'Free'
  'Basic'
])
param automationSkuName string = 'Basic'

@description('Name of the PowerShell runtime environment.')
param runtimeEnvironmentName string = 'PowerShell74'

@description('Runtime language version. PowerShell 7.4 is the current GA version supported by Azure Automation Runtime Environments.')
param runtimeVersion string = '7.4'

@description('Version of Az.Accounts explicitly imported in the runtime environment.')
param azAccountsPackageVersion string = '4.2.0'

@description('Package URI for Az.Accounts. Keep aligned with azAccountsPackageVersion.')
param azAccountsPackageUri string = 'https://www.powershellgallery.com/api/v2/package/Az.Accounts/4.2.0'

@description('Name of the PowerShell runbook.')
param runbookName string = 'Invoke-SqlStoredProcedure'

// ---------------------------------------------------------------------------
// Target Azure SQL (existing resources - parameterized, not created)
// ---------------------------------------------------------------------------
@description('Subscription ID hosting the existing Azure SQL logical server. Used as the scope of the optional firewall rule module.')
param sqlSubscriptionId string = subscription().subscriptionId

@description('Resource group name hosting the existing Azure SQL logical server. Used as the scope of the optional firewall rule module.')
param sqlResourceGroupName string = resourceGroup().name

@description('Name of the existing Azure SQL logical server (without .database.windows.net suffix).')
param sqlServerName string

@description('Name of the existing Azure SQL database.')
param sqlDatabaseName string

@description('Fully-qualified SQL server DNS name used by the runbook to connect. Defaults to the current Azure cloud SQL suffix.')
param sqlServerFqdn string = '${sqlServerName}${environment().suffixes.sqlServerHostname}'

@description('Name of the stored procedure to invoke (schema.procedure or procedure). No SQL parameters are passed.')
param storedProcedureName string

// ---------------------------------------------------------------------------
// Firewall
// ---------------------------------------------------------------------------
@description('Whether to create the "Allow Azure services" (0.0.0.0-0.0.0.0) firewall rule on the existing SQL server. SECURITY NOTE: this special range allows traffic from ANY Azure-hosted resource in ANY subscription/tenant to reach the server public endpoint (subject to further auth). It does not scope access to only your own resources. Prefer Private Endpoints/VNet service endpoints for stronger isolation; use this only when the public endpoint is required and you accept the broader network exposure, layered behind Entra-only auth and least-privilege DB permissions.')
param createAllowAzureServicesFirewallRule bool = true

@description('Name of the "Allow Azure services" firewall rule.')
param allowAzureServicesFirewallRuleName string = 'AllowAllWindowsAzureIps'

// ---------------------------------------------------------------------------
// Schedule
// ---------------------------------------------------------------------------
@description('Scheduling model. Single creates one native schedule; WeekdayHourlyWindow creates one Weekly schedule for each inclusive hour in the configured weekday window.')
@allowed([
  'Single'
  'WeekdayHourlyWindow'
])
param scheduleMode string = 'Single'

@description('Name of the Automation schedule.')
param scheduleName string

@description('Description of the schedule.')
param scheduleDescription string = ''

@description('Schedule frequency.')
@allowed([
  'OneTime'
  'Day'
  'Week'
  'Hour'
  'Minute'
  'Month'
])
param scheduleFrequency string = 'Day'

@description('Interval between runs. Ignored when scheduleFrequency is OneTime.')
@minValue(1)
param scheduleInterval int = 1

@description('Start time in ISO 8601 with UTC offset, e.g. 2025-01-01T02:00:00+00:00. Must be in the future.')
param scheduleStartTime string

@description('IANA/Windows time zone identifier, e.g. Europe/Rome.')
param scheduleTimeZone string = 'UTC'

@description('Optional expiry time (ISO 8601). Empty string = no expiry.')
param scheduleExpiryTime string = ''

@description('Days of week for Week frequency. Ignored otherwise.')
param scheduleWeekDays array = []

@description('Calendar date (YYYY-MM-DD) of the first WeekdayHourlyWindow execution. Must be a selected weekday and in the future.')
param weekdayHourlyWindowStartDate string = '2030-12-02'

@description('UTC offset used to build WeekdayHourlyWindow start times, for example +01:00.')
param weekdayHourlyWindowUtcOffset string = '+00:00'

@description('First hour of the weekday window, inclusive.')
@minValue(0)
@maxValue(23)
param weekdayHourlyWindowStartHour int = 8

@description('Last hour of the weekday window, inclusive.')
@minValue(0)
@maxValue(23)
param weekdayHourlyWindowEndHour int = 18

@description('Minute within each hourly window slot.')
@minValue(0)
@maxValue(59)
param weekdayHourlyWindowMinute int = 0

@description('Days used by WeekdayHourlyWindow mode.')
param weekdayHourlyWindowWeekDays array = [
  'Monday'
  'Tuesday'
  'Wednesday'
  'Thursday'
  'Friday'
]

@description('Set to true only after the runbook content has been published (second deployment pass) to link the schedule to the runbook and enable automatic execution.')
param enableJobSchedule bool = false

// ---------------------------------------------------------------------------
// Modules
// ---------------------------------------------------------------------------
module identity 'modules/managedIdentity.bicep' = {
  name: 'deploy-uami'
  params: {
    uamiName: uamiName
    location: location
    tags: tags
  }
}

module automation 'modules/automationAccount.bicep' = {
  name: 'deploy-automation-account'
  params: {
    automationAccountName: automationAccountName
    location: location
    automationSkuName: automationSkuName
    tags: tags
    userAssignedIdentityId: identity.outputs.id
    runtimeEnvironmentName: runtimeEnvironmentName
    runtimeVersion: runtimeVersion
    azAccountsPackageVersion: azAccountsPackageVersion
    azAccountsPackageUri: azAccountsPackageUri
    runbookName: runbookName
    sqlServerFqdn: sqlServerFqdn
    sqlDatabaseName: sqlDatabaseName
    storedProcedureName: storedProcedureName
    uamiClientId: identity.outputs.clientId
  }
}

module schedule 'modules/schedule.bicep' = {
  name: 'deploy-schedule'
  params: {
    automationAccountName: automation.outputs.name
    scheduleMode: scheduleMode
    scheduleName: scheduleName
    scheduleDescription: scheduleDescription
    frequency: scheduleFrequency
    interval: scheduleInterval
    startTime: scheduleStartTime
    timeZone: scheduleTimeZone
    expiryTime: scheduleExpiryTime
    weekDays: scheduleWeekDays
    weekdayHourlyWindowStartDate: weekdayHourlyWindowStartDate
    weekdayHourlyWindowUtcOffset: weekdayHourlyWindowUtcOffset
    weekdayHourlyWindowStartHour: weekdayHourlyWindowStartHour
    weekdayHourlyWindowEndHour: weekdayHourlyWindowEndHour
    weekdayHourlyWindowMinute: weekdayHourlyWindowMinute
    weekdayHourlyWindowWeekDays: weekdayHourlyWindowWeekDays
    runbookName: automation.outputs.runbookName
    enableJobSchedule: enableJobSchedule
  }
}

module sqlFirewallRule 'modules/sqlFirewallRule.bicep' = if (createAllowAzureServicesFirewallRule) {
  name: 'deploy-sql-firewall-rule'
  scope: resourceGroup(sqlSubscriptionId, sqlResourceGroupName)
  params: {
    sqlServerName: sqlServerName
    firewallRuleName: allowAzureServicesFirewallRuleName
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
@description('Resource ID of the created User Assigned Managed Identity.')
output uamiId string = identity.outputs.id

@description('Principal (object) ID of the UAMI, useful for Entra administration and diagnostics.')
output uamiPrincipalId string = identity.outputs.principalId

@description('Client (application) ID of the UAMI — used by Connect-AzAccount and as the SQL SID source for a managed identity.')
output uamiClientId string = identity.outputs.clientId

@description('Name of the created Automation Account.')
output automationAccountName string = automation.outputs.name

@description('Name of the created runbook (content published separately by deploy.ps1).')
output runbookName string = automation.outputs.runbookName

@description('Name of the runtime environment.')
output runtimeEnvironmentName string = automation.outputs.runtimeEnvironmentName

@description('Version of Az.Accounts explicitly imported into the runtime environment.')
output azAccountsPackageVersion string = automation.outputs.azAccountsPackageVersion

@description('Name of the created schedule.')
output scheduleName string = schedule.outputs.name

@description('Names of all schedules created for the selected scheduling mode.')
output scheduleNames array = schedule.outputs.scheduleNames

@description('Whether the schedule is currently linked (job schedule) to the runbook.')
output jobScheduleEnabled bool = schedule.outputs.jobScheduleEnabled

@description('Deterministic GUIDs of job schedule links active for the selected mode.')
output activeJobScheduleGuids array = schedule.outputs.activeJobScheduleGuids

@description('Candidate job schedule GUIDs removed before runbook publication.')
output cleanupJobScheduleGuids array = schedule.outputs.cleanupJobScheduleGuids

@description('Fully qualified SQL server DNS name to use in the runbook configuration / test connections.')
output sqlServerFqdn string = sqlServerFqdn

@description('Target SQL database name.')
output sqlDatabaseName string = sqlDatabaseName

@description('Stored procedure name the runbook will invoke.')
output storedProcedureName string = storedProcedureName
