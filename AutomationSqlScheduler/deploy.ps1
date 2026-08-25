<#
.SYNOPSIS
    Performs the idempotent two-phase deployment for AutomationSqlScheduler.

.DESCRIPTION
    Phase 1 deploys Bicep with the job schedule link disabled.
    Phase 2 uploads and publishes the local runbook through Azure REST.
    Phase 3 re-runs Bicep with the requested job schedule link state.

    This script never executes sql/bootstrap-uami-db-user.sql and never grants
    Azure RBAC permissions to the runbook UAMI.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string] $SubscriptionId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $ParametersFile,

    [ValidateNotNullOrEmpty()]
    [string] $DeploymentName = 'automation-sql-scheduler',

    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $RunbookPath = (Join-Path $PSScriptRoot 'runbooks\Invoke-SqlStoredProcedure.ps1'),

    [bool] $EnableJobSchedule = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ApiVersion = '2024-10-23'
$MainBicepPath = Join-Path $PSScriptRoot 'main.bicep'
$MinimumAzureCliVersion = [version]'2.53.1'
$PollIntervalSeconds = 5
$PollAttempts = 60

function Invoke-AzCli {
    param(
        [Parameter(Mandatory)]
        [string[]] $AzArguments,

        [switch] $DiscardOutput
    )

    $output = & az @AzArguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $renderedArguments = $AzArguments -join ' '
        $renderedOutput = ($output | Out-String).Trim()
        throw "Azure CLI command failed (az $renderedArguments).`n$renderedOutput"
    }

    if (-not $DiscardOutput) {
        return ($output | Out-String).Trim()
    }
}

function Wait-ForDraftContentHash {
    param(
        [Parameter(Mandatory)]
        [string] $DraftUri,

        [Parameter(Mandatory)]
        [string] $ExpectedHash
    )

    $lastResult = ''
    for ($attempt = 1; $attempt -le $PollAttempts; $attempt++) {
        $result = & az rest `
            --method get `
            --uri $DraftUri `
            --query 'draftContentLink.contentHash.value' `
            --output tsv `
            --only-show-errors 2>&1

        if ($LASTEXITCODE -eq 0) {
            $lastResult = ($result | Out-String).Trim()
            if ($lastResult.Equals($ExpectedHash, [StringComparison]::OrdinalIgnoreCase)) {
                return
            }
        }
        else {
            $lastResult = ($result | Out-String).Trim()
        }

        Start-Sleep -Seconds $PollIntervalSeconds
    }

    throw "Timed out waiting for Azure Automation to persist the uploaded runbook draft. Expected SHA256 '$ExpectedHash'; last result: '$lastResult'."
}

function Wait-ForPublishedRunbook {
    param(
        [Parameter(Mandatory)]
        [string] $RunbookUri
    )

    $lastState = ''
    for ($attempt = 1; $attempt -le $PollAttempts; $attempt++) {
        $result = & az rest `
            --method get `
            --uri $RunbookUri `
            --query 'properties.state' `
            --output tsv `
            --only-show-errors 2>&1

        if ($LASTEXITCODE -eq 0) {
            $lastState = ($result | Out-String).Trim()
            if ($lastState -eq 'Published') {
                return
            }
        }
        else {
            $lastState = ($result | Out-String).Trim()
        }

        Start-Sleep -Seconds $PollIntervalSeconds
    }

    throw "Timed out waiting for runbook publication. Last state/result: '$lastState'."
}

function Remove-JobScheduleIfPresent {
    param(
        [Parameter(Mandatory)]
        [string] $JobScheduleUri
    )

    $lookupResult = & az rest `
        --method get `
        --uri $JobScheduleUri `
        --output none `
        --only-show-errors 2>&1

    if ($LASTEXITCODE -eq 0) {
        Invoke-AzCli -AzArguments @(
            'rest',
            '--method', 'delete',
            '--uri', $JobScheduleUri,
            '--output', 'none',
            '--only-show-errors'
        ) -DiscardOutput
        return
    }

    $lookupMessage = ($lookupResult | Out-String).Trim()
    if ($lookupMessage -match '(?i)404|ResourceNotFound|could not be found') {
        return
    }

    throw "Unable to determine whether the existing job schedule link is present.`n$lookupMessage"
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) is required and was not found on PATH.'
}

if (-not (Test-Path -LiteralPath $MainBicepPath -PathType Leaf)) {
    throw "Bicep entry point not found: '$MainBicepPath'."
}

$ParametersFile = (Resolve-Path -LiteralPath $ParametersFile).Path
$RunbookPath = (Resolve-Path -LiteralPath $RunbookPath).Path

if ([IO.Path]::GetExtension($ParametersFile) -ne '.bicepparam') {
    throw "ParametersFile must be a .bicepparam file: '$ParametersFile'."
}

$cliVersionJson = Invoke-AzCli -AzArguments @('version', '--output', 'json', '--only-show-errors')
$cliVersion = [version](($cliVersionJson | ConvertFrom-Json).'azure-cli')
if ($cliVersion -lt $MinimumAzureCliVersion) {
    throw "Azure CLI $MinimumAzureCliVersion or later is required for .bicepparam support. Found $cliVersion."
}

Invoke-AzCli -AzArguments @('bicep', 'version', '--only-show-errors') -DiscardOutput
Invoke-AzCli -AzArguments @('bicep', 'build', '--file', $MainBicepPath, '--stdout', '--only-show-errors') -DiscardOutput
Invoke-AzCli -AzArguments @('bicep', 'build-params', '--file', $ParametersFile, '--stdout', '--only-show-errors') -DiscardOutput

# This verifies an existing authenticated context without ever invoking an
# interactive `az login`.
Invoke-AzCli -AzArguments @('account', 'show', '--output', 'none', '--only-show-errors') -DiscardOutput
Invoke-AzCli -AzArguments @('account', 'set', '--subscription', $SubscriptionId, '--only-show-errors') -DiscardOutput

$selectedSubscription = Invoke-AzCli -AzArguments @(
    'account', 'show',
    '--query', 'id',
    '--output', 'tsv',
    '--only-show-errors'
)
if ($selectedSubscription -ne $SubscriptionId) {
    throw "Azure CLI selected subscription '$selectedSubscription', expected '$SubscriptionId'."
}

Invoke-AzCli -AzArguments @(
    'group', 'show',
    '--name', $ResourceGroupName,
    '--subscription', $SubscriptionId,
    '--output', 'none',
    '--only-show-errors'
) -DiscardOutput

$commonDeploymentArguments = @(
    'deployment', 'group', 'create',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--parameters', $ParametersFile,
    '--mode', 'Incremental',
    '--only-show-errors'
)

Write-Host 'Phase 1/3: deploying infrastructure and schedule with job link disabled...'
$phaseOneOutputJson = Invoke-AzCli -AzArguments (
    $commonDeploymentArguments + @(
        '--name', "$DeploymentName-phase1",
        '--parameters', 'enableJobSchedule=false',
        '--query', 'properties.outputs',
        '--output', 'json'
    )
)
$phaseOneOutputs = $phaseOneOutputJson | ConvertFrom-Json

$automationAccountName = [string]$phaseOneOutputs.automationAccountName.value
$runbookName = [string]$phaseOneOutputs.runbookName.value
$activeJobScheduleGuids = @(
    $phaseOneOutputs.activeJobScheduleGuids.value | ForEach-Object { [string] $_ }
)
$cleanupJobScheduleGuids = @(
    $phaseOneOutputs.cleanupJobScheduleGuids.value | ForEach-Object { [string] $_ }
)
if (
    [string]::IsNullOrWhiteSpace($automationAccountName) -or
    [string]::IsNullOrWhiteSpace($runbookName) -or
    $activeJobScheduleGuids.Count -eq 0 -or
    $cleanupJobScheduleGuids.Count -eq 0
) {
    throw 'The phase 1 deployment did not return the required account, runbook, and job schedule outputs.'
}

$encodedResourceGroup = [Uri]::EscapeDataString($ResourceGroupName)
$encodedAccountName = [Uri]::EscapeDataString($automationAccountName)
$encodedRunbookName = [Uri]::EscapeDataString($runbookName)
$runbookBaseUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$encodedResourceGroup/providers/Microsoft.Automation/automationAccounts/$encodedAccountName/runbooks/$encodedRunbookName"
$runbookUri = "${runbookBaseUri}?api-version=$ApiVersion"
$draftUri = "${runbookBaseUri}/draft?api-version=$ApiVersion"
$draftContentUri = "${runbookBaseUri}/draft/content?api-version=$ApiVersion"
$publishUri = "${runbookBaseUri}/publish?api-version=$ApiVersion"
$jobScheduleBaseUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$encodedResourceGroup/providers/Microsoft.Automation/automationAccounts/$encodedAccountName/jobSchedules"

# ARM Incremental mode does not delete a resource omitted by a false
# condition. Remove only the deterministic candidate links so phase 1 is
# genuinely disabled for both single and multi-slot scheduling modes.
foreach ($jobScheduleGuid in $cleanupJobScheduleGuids) {
    $jobScheduleUri = "${jobScheduleBaseUri}/${jobScheduleGuid}?api-version=$ApiVersion"
    Remove-JobScheduleIfPresent -JobScheduleUri $jobScheduleUri
}

Write-Host "Phase 2/3: uploading and publishing local runbook '$RunbookPath'..."
$runbookHash = (Get-FileHash -LiteralPath $RunbookPath -Algorithm SHA256).Hash

Invoke-AzCli -AzArguments @(
    'rest',
    '--method', 'put',
    '--uri', $draftContentUri,
    '--headers', 'Content-Type=text/plain',
    '--body', "@$RunbookPath",
    '--output', 'none',
    '--only-show-errors'
) -DiscardOutput

Wait-ForDraftContentHash -DraftUri $draftUri -ExpectedHash $runbookHash

Invoke-AzCli -AzArguments @(
    'rest',
    '--method', 'post',
    '--uri', $publishUri,
    '--output', 'none',
    '--only-show-errors'
) -DiscardOutput

Wait-ForPublishedRunbook -RunbookUri $runbookUri

$jobScheduleValue = $EnableJobSchedule.ToString().ToLowerInvariant()
Write-Host "Phase 3/3: applying final job schedule link state: $jobScheduleValue..."
Invoke-AzCli -AzArguments (
    $commonDeploymentArguments + @(
        '--name', "$DeploymentName-phase3",
        '--parameters', "enableJobSchedule=$jobScheduleValue",
        '--output', 'none'
    )
) -DiscardOutput

Write-Host 'Deployment flow completed successfully.'
Write-Host "Automation Account: $automationAccountName"
Write-Host "Runbook: $runbookName (Published)"
Write-Host "Job schedule links requested: $jobScheduleValue (active link count: $($activeJobScheduleGuids.Count))"
Write-Warning 'Database bootstrap was NOT executed. Run sql\bootstrap-uami-db-user.sql manually as an authorized Microsoft Entra administrator.'
