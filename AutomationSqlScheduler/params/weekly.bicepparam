using '../main.bicep'

// -----------------------------------------------------------------------
// Example parameter file: Weekly schedule (runs on selected week days)
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

// Schedule: Weekly - runs every `scheduleInterval` weeks on the given weekDays
param scheduleName = 'sch-sql-scheduler-weekly'
param scheduleDescription = 'Runs the SQL scheduler runbook every Monday and Thursday at 03:00 Europe/Rome.'
param scheduleFrequency = 'Week'
param scheduleInterval = 1 // every 1 week
param scheduleStartTime = '2030-12-02T03:00:00+01:00' // Monday; replace with a future matching weekday
param scheduleTimeZone = 'Europe/Rome'
param scheduleExpiryTime = ''
param scheduleWeekDays = [
  'Monday'
  'Thursday'
]

// Keep false until deploy.ps1 has published the runbook content (phase 2),
// then re-run the deployment with this set to true to link the schedule.
param enableJobSchedule = false
