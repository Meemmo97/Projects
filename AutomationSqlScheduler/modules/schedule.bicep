// Azure Automation scheduling supports a single recurrence time per schedule.
// A weekday hourly window is therefore modeled as one Weekly schedule for each
// inclusive hour in the configured window, all sharing Monday-Friday (or the
// configured weekday list).

@description('Name of the Automation Account (existing, deployed by automationAccount.bicep).')
param automationAccountName string

@description('Scheduling model: Single creates one native Automation schedule; WeekdayHourlyWindow creates one Weekly schedule per inclusive hour in the window.')
@allowed([
  'Single'
  'WeekdayHourlyWindow'
])
param scheduleMode string = 'Single'

@description('Base name of the Automation schedule. Window schedules append HHmm.')
param scheduleName string

@description('Description of the schedule.')
param scheduleDescription string = ''

@description('Frequency used by Single mode.')
@allowed([
  'OneTime'
  'Day'
  'Week'
  'Hour'
  'Minute'
  'Month'
])
param frequency string = 'Day'

@description('Interval between runs. In window mode this is the number of weeks between active weeks. Ignored for Single/OneTime.')
@minValue(1)
param interval int = 1

@description('Start time for Single mode in ISO 8601 format including UTC offset.')
param startTime string

@description('IANA/Windows time zone identifier used by all schedules.')
param timeZone string = 'UTC'

@description('Optional expiry time for all schedules (ISO 8601). Empty means no expiry.')
param expiryTime string = ''

@description('Days of week used by Single/Week frequency.')
param weekDays array = []

@description('Calendar date of the first window execution, formatted YYYY-MM-DD. It must be a configured weekday and in the future.')
param weekdayHourlyWindowStartDate string = '2030-12-02'

@description('UTC offset appended to window start times, for example +01:00 or +00:00.')
param weekdayHourlyWindowUtcOffset string = '+00:00'

@description('First hour in the weekday window, inclusive.')
@minValue(0)
@maxValue(23)
param weekdayHourlyWindowStartHour int = 8

@description('Last hour in the weekday window, inclusive.')
@minValue(0)
@maxValue(23)
param weekdayHourlyWindowEndHour int = 18

@description('Minute within every hourly slot, for example 0 produces 08:00, 09:00, and so on.')
@minValue(0)
@maxValue(59)
param weekdayHourlyWindowMinute int = 0

@description('Weekdays used by WeekdayHourlyWindow mode.')
param weekdayHourlyWindowWeekDays array = [
  'Monday'
  'Tuesday'
  'Wednesday'
  'Thursday'
  'Friday'
]

@description('Name of the runbook to link to the schedule or schedules.')
param runbookName string

@description('Whether to create job schedule links. Keep false until the runbook content has been published.')
param enableJobSchedule bool = false

var isHourlyWindow = scheduleMode == 'WeekdayHourlyWindow'
var hourlyWindowSlotCount = !isHourlyWindow
  ? 0
  : weekdayHourlyWindowEndHour >= weekdayHourlyWindowStartHour
    ? weekdayHourlyWindowEndHour - weekdayHourlyWindowStartHour + 1
    : fail('weekdayHourlyWindowEndHour must be greater than or equal to weekdayHourlyWindowStartHour.')
var validatedHourlyWindowWeekDays = !isHourlyWindow || !empty(weekdayHourlyWindowWeekDays)
  ? weekdayHourlyWindowWeekDays
  : fail('weekdayHourlyWindowWeekDays must contain at least one day.')
var hourlyWindowHours = range(weekdayHourlyWindowStartHour, hourlyWindowSlotCount)
var paddedMinute = padLeft(string(weekdayHourlyWindowMinute), 2, '0')
var hourlyWindowScheduleNames = [
  for hour in hourlyWindowHours: '${scheduleName}-${padLeft(string(hour), 2, '0')}${paddedMinute}'
]
var hourlyWindowStartTimes = [
  for hour in hourlyWindowHours: '${weekdayHourlyWindowStartDate}T${padLeft(string(hour), 2, '0')}:${paddedMinute}:00${weekdayHourlyWindowUtcOffset}'
]
var singleJobScheduleGuid = guid(automationAccountName, scheduleName, runbookName)
var hourlyWindowJobScheduleGuids = [
  for hourlyScheduleName in hourlyWindowScheduleNames: guid(automationAccountName, hourlyScheduleName, runbookName)
]
var activeScheduleNames = isHourlyWindow ? hourlyWindowScheduleNames : [
  scheduleName
]
var activeJobScheduleGuids = isHourlyWindow ? hourlyWindowJobScheduleGuids : [
  singleJobScheduleGuid
]

resource automationAccount 'Microsoft.Automation/automationAccounts@2024-10-23' existing = {
  name: automationAccountName
}

resource singleSchedule 'Microsoft.Automation/automationAccounts/schedules@2024-10-23' = if (!isHourlyWindow) {
  parent: automationAccount
  name: scheduleName
  properties: union(
    {
      description: scheduleDescription
      frequency: frequency
      startTime: startTime
      timeZone: timeZone
    },
    empty(expiryTime) ? {} : { expiryTime: expiryTime },
    (frequency == 'Week' && !empty(weekDays)) ? { advancedSchedule: { weekDays: weekDays } } : {},
    frequency == 'OneTime' ? {} : { interval: interval }
  )
}

resource hourlyWindowSchedules 'Microsoft.Automation/automationAccounts/schedules@2024-10-23' = [
  for (hour, index) in hourlyWindowHours: if (isHourlyWindow) {
    parent: automationAccount
    name: hourlyWindowScheduleNames[index]
    properties: union(
      {
        description: '${scheduleDescription} Hourly slot ${padLeft(string(hour), 2, '0')}:${paddedMinute}.'
        frequency: 'Week'
        interval: interval
        startTime: hourlyWindowStartTimes[index]
        timeZone: timeZone
        advancedSchedule: {
          weekDays: validatedHourlyWindowWeekDays
        }
      },
      empty(expiryTime) ? {} : { expiryTime: expiryTime }
    )
  }
]

resource singleJobSchedule 'Microsoft.Automation/automationAccounts/jobSchedules@2024-10-23' = if (enableJobSchedule && !isHourlyWindow) {
  parent: automationAccount
  name: singleJobScheduleGuid
  properties: {
    schedule: {
      name: singleSchedule.name
    }
    runbook: {
      name: runbookName
    }
  }
}

resource hourlyWindowJobSchedules 'Microsoft.Automation/automationAccounts/jobSchedules@2024-10-23' = [
  for (jobScheduleGuid, index) in hourlyWindowJobScheduleGuids: if (enableJobSchedule && isHourlyWindow) {
    parent: automationAccount
    name: jobScheduleGuid
    properties: {
      schedule: {
        name: hourlyWindowSchedules[index].name
      }
      runbook: {
        name: runbookName
      }
    }
  }
]

@description('Base schedule name.')
output name string = scheduleName

@description('Names of the schedules active for the selected mode.')
output scheduleNames array = activeScheduleNames

@description('Whether the active schedule or schedules were linked to the runbook.')
output jobScheduleEnabled bool = enableJobSchedule

@description('Deterministic GUIDs of active job schedule links, including when link creation is disabled.')
output activeJobScheduleGuids array = activeJobScheduleGuids

@description('Candidate GUIDs that deploy.ps1 removes before publication, covering both scheduling modes for the configured names/window.')
output cleanupJobScheduleGuids array = union([
  singleJobScheduleGuid
], hourlyWindowJobScheduleGuids)
