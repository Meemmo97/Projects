using '../main.bicep'

// ---------------------------------------------------------------------------
// Example: Monday-Friday, every hour from 08:00 through 18:00 inclusive.
//
// Azure Automation cannot express this pattern with one native schedule.
// The template creates 11 Weekly schedules (0800, 0900, ..., 1800), each
// active Monday-Friday and linked to the same runbook.
// ---------------------------------------------------------------------------

param location = 'westeurope'

param tags = {
  environment: 'dev'
  workload: 'automation-sql-scheduler'
}

// Naming and runtime
param uamiName = 'id-sql-scheduler-dev'
param automationAccountName = 'aa-sql-scheduler-dev'
param automationSkuName = 'Basic'
param runtimeEnvironmentName = 'PowerShell74'
param runtimeVersion = '7.4'
param azAccountsPackageVersion = '4.2.0'
param azAccountsPackageUri = 'https://www.powershellgallery.com/api/v2/package/Az.Accounts/4.2.0'
param runbookName = 'Invoke-SqlStoredProcedure'

// Existing Azure SQL target
param sqlSubscriptionId = '00000000-0000-0000-0000-000000000000'
param sqlResourceGroupName = 'rg-sql-prod'
param sqlServerName = 'sql-logical-server-example'
param sqlDatabaseName = 'sampledb'
param storedProcedureName = 'dbo.usp_RunScheduledJob'

// Public endpoint firewall
param createAllowAzureServicesFirewallRule = true
param allowAzureServicesFirewallRuleName = 'AllowAllWindowsAzureIps'

// Weekday hourly window. End hour is inclusive: 8..18 creates 11 slots.
param scheduleMode = 'WeekdayHourlyWindow'
param scheduleName = 'sch-sql-scheduler-business-hours'
param scheduleDescription = 'Runs the SQL procedure hourly on working days from 08:00 through 18:00.'

// Used as the weekly interval in window mode: 1 means every week.
param scheduleInterval = 1

// Shared time zone and optional expiry for every generated schedule.
param scheduleTimeZone = 'Europe/Rome'
param scheduleExpiryTime = ''

// The first date must be a configured weekday and in the future. 2030-12-02
// is a Monday. Keep its UTC offset consistent with Europe/Rome on that date.
param weekdayHourlyWindowStartDate = '2030-12-02'
param weekdayHourlyWindowUtcOffset = '+01:00'
param weekdayHourlyWindowStartHour = 8
param weekdayHourlyWindowEndHour = 18
param weekdayHourlyWindowMinute = 0
param weekdayHourlyWindowWeekDays = [
  'Monday'
  'Tuesday'
  'Wednesday'
  'Thursday'
  'Friday'
]

// Required by the common Single-mode interface but ignored in window mode.
param scheduleFrequency = 'Week'
param scheduleStartTime = '2030-12-02T08:00:00+01:00'
param scheduleWeekDays = []

// Keep false in source. deploy.ps1 forces false during phase 1 and applies
// the -EnableJobSchedule value only after publishing the local runbook.
param enableJobSchedule = false
