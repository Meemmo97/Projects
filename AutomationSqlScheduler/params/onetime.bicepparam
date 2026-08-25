using '../main.bicep'

// -----------------------------------------------------------------------
// Example parameter file: OneTime schedule (single execution slot)
// -----------------------------------------------------------------------

param location = 'westeurope'

param tags = {
  environment: 'dev'
  workload: 'automation-sql-scheduler'
}

// Naming
param uamiName = 'id-sql-scheduler-dev'
param automationAccountName = 'aa-sql-scheduler-dev'
param automationSkuName = 'Basic'
param runtimeEnvironmentName = 'PowerShell74'
param runtimeVersion = '7.4'
param azAccountsPackageVersion = '4.2.0'
param azAccountsPackageUri = 'https://www.powershellgallery.com/api/v2/package/Az.Accounts/4.2.0'
param runbookName = 'Invoke-SqlStoredProcedure'

// Target Azure SQL (existing resources)
param sqlSubscriptionId = '00000000-0000-0000-0000-000000000000'
param sqlResourceGroupName = 'rg-sql-prod'
param sqlServerName = 'sql-logical-server-example'
param sqlDatabaseName = 'sampledb'
param storedProcedureName = 'dbo.usp_RunScheduledJob'

// Firewall
param createAllowAzureServicesFirewallRule = true
param allowAzureServicesFirewallRuleName = 'AllowAllWindowsAzureIps'

// Schedule: OneTime - fires once at the given startTime
param scheduleName = 'sch-sql-scheduler-onetime'
param scheduleDescription = 'One-time execution of the SQL scheduler runbook.'
param scheduleFrequency = 'OneTime'
param scheduleInterval = 1 // ignored for OneTime
param scheduleStartTime = '2030-12-01T02:00:00+01:00' // replace with a future time before deployment
param scheduleTimeZone = 'Europe/Rome'
param scheduleExpiryTime = ''
param scheduleWeekDays = [] // ignored for OneTime

// Keep false until deploy.ps1 has published the runbook content (phase 2),
// then re-run the deployment with this set to true to link the schedule.
param enableJobSchedule = false
