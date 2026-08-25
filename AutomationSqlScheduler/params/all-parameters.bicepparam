using '../main.bicep'

// =============================================================================
// Complete example: every parameter exposed by main.bicep
//
// This example uses a Daily schedule. Replace every placeholder before use.
// Keep enableJobSchedule=false for the first deploy.ps1 invocation, execute the
// SQL bootstrap manually, then let deploy.ps1 override it to true only when
// you intentionally enable the schedule.
// =============================================================================

// Azure region for the new UAMI and Automation Account. The existing SQL
// logical server can be in another region.
param location = 'westeurope'

// Tags applied to resources that support tags.
param tags = {
  environment: 'dev'
  workload: 'automation-sql-scheduler'
  owner: 'data-platform'
  managedBy: 'bicep'
}

// Name of the new User Assigned Managed Identity.
param uamiName = 'id-sql-scheduler-dev'

// Globally unique name of the new Azure Automation Account.
param automationAccountName = 'aa-sql-scheduler-dev'

// Automation SKU: Basic is recommended for production use; Free is supported
// for limited/test workloads subject to Azure service quotas.
param automationSkuName = 'Basic'

// Name of the custom Runtime Environment.
param runtimeEnvironmentName = 'PowerShell74'

// GA PowerShell runtime version supported by the current Automation API.
param runtimeVersion = '7.4'

// Az.Accounts version imported into the Runtime Environment.
param azAccountsPackageVersion = '4.2.0'

// Download URI for the exact Az.Accounts package version above. Keep URI and
// version aligned; this URI is only for the module, never for runbook code.
param azAccountsPackageUri = 'https://www.powershellgallery.com/api/v2/package/Az.Accounts/4.2.0'

// Name of the runbook shell created by Bicep and populated by deploy.ps1 from
// the local runbooks/Invoke-SqlStoredProcedure.ps1 file.
param runbookName = 'Invoke-SqlStoredProcedure'

// Subscription containing the EXISTING Azure SQL logical server. It can differ
// from the deployment subscription if the operator has permissions on both.
param sqlSubscriptionId = '00000000-0000-0000-0000-000000000000'

// Resource group containing the existing Azure SQL logical server.
param sqlResourceGroupName = 'rg-sql-prod'

// Existing logical server name, without the DNS suffix.
param sqlServerName = 'sql-logical-server-example'

// Existing Azure SQL database containing the stored procedure.
param sqlDatabaseName = 'sampledb'

// Full public endpoint used by the runbook. For Azure public cloud this is
// <server>.database.windows.net. Sovereign clouds use their own DNS suffix.
// Remove this explicit parameter to use main.bicep's cloud-aware default.
param sqlServerFqdn = 'sql-logical-server-example.database.windows.net'

// Stored procedure invoked without SQL parameters. Use schema.procedure;
// identifiers accept only letters, digits, underscores, and must start with a
// letter or underscore.
param storedProcedureName = 'dbo.usp_RunScheduledJob'

// Creates the special 0.0.0.0-0.0.0.0 Azure SQL firewall rule. This exposes
// the public endpoint to traffic originating from Azure generally, not only
// from this subscription/tenant. Set false if suitable network access already
// exists.
param createAllowAzureServicesFirewallRule = true

// Name assigned to the optional firewall rule on the existing SQL server.
param allowAzureServicesFirewallRuleName = 'AllowAllWindowsAzureIps'

// Scheduling model. Single creates one native schedule. The alternative
// WeekdayHourlyWindow creates one Weekly schedule per inclusive window hour.
param scheduleMode = 'Single'

// Base name of the Azure Automation schedule. Window schedules append HHmm.
param scheduleName = 'sch-sql-scheduler-daily'

// Human-readable description shown on the Automation schedule.
param scheduleDescription = 'Runs dbo.usp_RunScheduledJob every day at 02:00 Europe/Rome.'

// Schedule frequency: OneTime, Day, Week, Hour, Minute, or Month.
param scheduleFrequency = 'Day'

// Number of frequency units between executions. Must be at least 1 and is
// ignored for OneTime.
param scheduleInterval = 1

// First execution time in ISO 8601 format including UTC offset. It must be in
// the future when deployed.
param scheduleStartTime = '2030-12-01T02:00:00+01:00'

// Time zone interpreted by Azure Automation for recurring schedule behavior.
param scheduleTimeZone = 'Europe/Rome'

// Optional ISO 8601 expiry time. Empty means no expiry.
param scheduleExpiryTime = ''

// Used only when scheduleFrequency='Week'. Valid values are Monday through
// Sunday. Empty for this Daily example.
param scheduleWeekDays = []

// WeekdayHourlyWindow-only settings. They remain explicitly documented here
// even though scheduleMode='Single' ignores them.

// Date of the first window execution (YYYY-MM-DD). It must be a selected
// weekday and in the future.
param weekdayHourlyWindowStartDate = '2030-12-02'

// UTC offset valid for the start date/time zone above.
param weekdayHourlyWindowUtcOffset = '+01:00'

// Inclusive first and last window hours. 8 through 18 creates 11 schedules.
param weekdayHourlyWindowStartHour = 8
param weekdayHourlyWindowEndHour = 18

// Minute used by every slot: 30 means 08:30, 09:30, and so on.
param weekdayHourlyWindowMinute = 0

// Working days associated with every generated Weekly schedule.
param weekdayHourlyWindowWeekDays = [
  'Monday'
  'Tuesday'
  'Wednesday'
  'Thursday'
  'Friday'
]

// Creates the deterministic runbook-to-schedule job link. deploy.ps1 always
// forces false during phase 1 and applies the requested final state only after
// the local runbook has been uploaded and published.
param enableJobSchedule = false
