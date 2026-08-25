<#
.SYNOPSIS
    Executes two parameterless Azure SQL stored procedures sequentially using
    a User Assigned Managed Identity.

.DESCRIPTION
    Configure the two procedure names in $StoredProcedureNames below.

    Each stored procedure has an independent timeout of 600 seconds (10
    minutes). If the first procedure fails or times out, the second procedure
    is not executed and the runbook fails.

    Database access for this workload is configured by:
      sql/configure-lightmes-uami-permissions.sql

    In addition to EXECUTE on both procedures, that script grants SELECT,
    INSERT, UPDATE, DELETE, and ALTER on Shifts, OperationsManaged, and
    vv_Operations. ALTER is required by the workload's TRUNCATE operation.
#>

#Requires -Version 7.2

$ErrorActionPreference = 'Stop'
$WarningPreference = 'Continue'

# Workload configuration. These values are identifiers, not credentials.
$SqlServerFqdn = 'prod-sql01-lightmes-e74gj.database.windows.net'
$SqlDatabaseName = 'prod-db01-lightmes-e74gj'
$UamiClientId = '6ca2a520-2159-403d-bf01-6a7a9aefce0e'

$StoredProcedureNames = @(
    'dbo.sp_SplitOrder'
    'dbo.sp_STD_DateMin'
)

$CommandTimeoutSeconds = 600
$AzAccountsVersion = '2.12.4'
$currentStep = 'STARTUP'
$runbookStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

function Write-RunbookLog {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string] $Level,

        [Parameter(Mandatory)]
        [string] $Step,

        [Parameter(Mandatory)]
        [string] $Message
    )

    $timestamp = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    Write-Output "[$timestamp] [$Level] [$Step] $Message"
}

function Get-SafeQualifiedProcedureName {
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )

    $trimmedName = $Name.Trim()
    $parts = $trimmedName.Split('.')

    if ($parts.Count -lt 1 -or $parts.Count -gt 2) {
        throw "Invalid stored procedure name '$Name'. Use procedure or schema.procedure."
    }

    foreach ($part in $parts) {
        if ($part -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            throw "Invalid SQL identifier '$part' in '$Name'. Only letters, digits, and underscores are allowed, and each part must start with a letter or underscore."
        }
    }

    return (($parts | ForEach-Object { '[{0}]' -f $_ }) -join '.')
}

try {
    Write-RunbookLog -Level INFO -Step STARTUP -Message "Runbook started on PowerShell $($PSVersionTable.PSVersion)."

    $currentStep = 'MODULE'
    Write-RunbookLog -Level INFO -Step $currentStep -Message "Loading Az.Accounts $AzAccountsVersion."
    $moduleWarnings = @()

    Import-Module Az.Accounts `
        -RequiredVersion $AzAccountsVersion `
        -Force `
        -ErrorAction Stop `
        -WarningAction SilentlyContinue `
        -WarningVariable moduleWarnings

    foreach ($moduleWarning in $moduleWarnings) {
        Write-RunbookLog -Level WARN -Step $currentStep -Message $moduleWarning.Message
    }

    $loadedAzAccounts = Get-Module Az.Accounts |
        Where-Object Version -eq ([version] $AzAccountsVersion) |
        Select-Object -First 1

    if ($null -eq $loadedAzAccounts) {
        throw "Az.Accounts $AzAccountsVersion was not loaded."
    }

    foreach ($commandName in @(
        'Disable-AzContextAutosave'
        'Connect-AzAccount'
        'Get-AzAccessToken'
    )) {
        if ($null -eq (Get-Command $commandName -ErrorAction SilentlyContinue)) {
            throw "Required command '$commandName' is unavailable after importing Az.Accounts $AzAccountsVersion."
        }
    }

    Write-RunbookLog -Level INFO -Step $currentStep -Message "Az.Accounts $($loadedAzAccounts.Version) loaded successfully."

    $currentStep = 'CONFIG'
    Disable-AzContextAutosave -Scope Process | Out-Null

    $parsedClientId = [Guid]::Empty
    if (-not [Guid]::TryParse($UamiClientId, [ref] $parsedClientId)) {
        throw 'UamiClientId must contain a valid GUID.'
    }

    if ($StoredProcedureNames.Count -ne 2) {
        throw 'Exactly two stored procedure names must be configured.'
    }

    $safeProcedureNames = @(
        $StoredProcedureNames | ForEach-Object {
            Get-SafeQualifiedProcedureName -Name $_
        }
    )
    Write-RunbookLog -Level INFO -Step $currentStep -Message "Configuration validated for server '$SqlServerFqdn', database '$SqlDatabaseName', and two stored procedures."

    $currentStep = 'AUTH'
    Write-RunbookLog -Level INFO -Step $currentStep -Message "Authenticating with the User Assigned Managed Identity (client ID ending in ...$($UamiClientId.Substring($UamiClientId.Length - 4)))."
    $authenticationStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $null = Connect-AzAccount -Identity -AccountId $UamiClientId

    $tokenResponse = Get-AzAccessToken -ResourceUrl 'https://database.windows.net/'
    if ($null -eq $tokenResponse -or $null -eq $tokenResponse.Token) {
        throw 'Unable to acquire an Azure SQL access token.'
    }

    if ($tokenResponse.Token -is [System.Security.SecureString]) {
        $accessToken = [System.Net.NetworkCredential]::new('', $tokenResponse.Token).Password
    }
    else {
        $accessToken = [string] $tokenResponse.Token
    }

    if ([string]::IsNullOrWhiteSpace($accessToken)) {
        throw 'The Azure SQL access token is empty.'
    }
    $authenticationStopwatch.Stop()
    Write-RunbookLog -Level INFO -Step $currentStep -Message "Managed Identity authentication and Azure SQL token acquisition completed in $($authenticationStopwatch.Elapsed.TotalSeconds.ToString('F2')) seconds."

    $currentStep = 'SQL-CONNECTION'
    $connectionStringBuilder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
    $connectionStringBuilder['Data Source'] = "tcp:$SqlServerFqdn,1433"
    $connectionStringBuilder['Initial Catalog'] = $SqlDatabaseName
    $connectionStringBuilder['Encrypt'] = $true
    $connectionStringBuilder['TrustServerCertificate'] = $false
    $connectionStringBuilder['Connect Timeout'] = 30

    $connection = [System.Data.SqlClient.SqlConnection]::new(
        $connectionStringBuilder.ConnectionString
    )
    $connection.AccessToken = $accessToken

    try {
        $connectionStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Write-RunbookLog -Level INFO -Step $currentStep -Message "Opening encrypted SQL connection to database '$SqlDatabaseName' on '$SqlServerFqdn'."
        $connection.Open()
        $connectionStopwatch.Stop()
        Write-RunbookLog -Level INFO -Step $currentStep -Message "SQL connection opened in $($connectionStopwatch.Elapsed.TotalSeconds.ToString('F2')) seconds."

        for ($index = 0; $index -lt $safeProcedureNames.Count; $index++) {
            $procedureName = $safeProcedureNames[$index]
            $sequenceNumber = $index + 1
            $currentStep = "PROCEDURE-$sequenceNumber"
            $command = $connection.CreateCommand()
            $procedureStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

            try {
                $command.CommandType = [System.Data.CommandType]::Text
                $command.CommandText = "EXEC $procedureName;"
                $command.CommandTimeout = $CommandTimeoutSeconds

                Write-RunbookLog -Level INFO -Step $currentStep -Message "Executing '$procedureName' with an independent timeout of $CommandTimeoutSeconds seconds."
                $rowsAffected = $command.ExecuteNonQuery()
                $procedureStopwatch.Stop()
                Write-RunbookLog -Level INFO -Step $currentStep -Message "'$procedureName' completed in $($procedureStopwatch.Elapsed.TotalSeconds.ToString('F2')) seconds. Rows affected: $rowsAffected."
            }
            catch {
                $procedureStopwatch.Stop()
                $procedureException = $_.Exception
                Write-RunbookLog -Level ERROR -Step $currentStep -Message "'$procedureName' failed after $($procedureStopwatch.Elapsed.TotalSeconds.ToString('F2')) seconds. Exception type: $($procedureException.GetType().FullName). Message: $($procedureException.Message)"

                $sqlException = $procedureException
                while (
                    $null -ne $sqlException -and
                    $sqlException -isnot [System.Data.SqlClient.SqlException]
                ) {
                    $sqlException = $sqlException.InnerException
                }

                if ($sqlException -is [System.Data.SqlClient.SqlException]) {
                    foreach ($sqlError in $sqlException.Errors) {
                        Write-RunbookLog -Level ERROR -Step $currentStep -Message "SQL error Number=$($sqlError.Number), State=$($sqlError.State), Class=$($sqlError.Class), Procedure='$($sqlError.Procedure)', Line=$($sqlError.LineNumber): $($sqlError.Message)"
                    }
                }

                throw
            }
            finally {
                $command.Dispose()
            }
        }
    }
    finally {
        if ($connection.State -eq [System.Data.ConnectionState]::Open) {
            $connection.Close()
        }

        $connection.Dispose()
        $accessToken = $null
    }

    $runbookStopwatch.Stop()
    Write-RunbookLog -Level INFO -Step COMPLETE -Message "Both stored procedures completed successfully. Total duration: $($runbookStopwatch.Elapsed.TotalSeconds.ToString('F2')) seconds."
}
catch {
    $runbookStopwatch.Stop()
    $exception = $_.Exception
    Write-RunbookLog -Level ERROR -Step $currentStep -Message "Runbook failed after $($runbookStopwatch.Elapsed.TotalSeconds.ToString('F2')) seconds. Exception type: $($exception.GetType().FullName). Message: $($exception.Message)"

    if ($null -ne $exception.InnerException) {
        Write-RunbookLog -Level ERROR -Step $currentStep -Message "Inner exception: $($exception.InnerException.GetType().FullName): $($exception.InnerException.Message)"
    }

    if (-not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) {
        Write-RunbookLog -Level ERROR -Step $currentStep -Message "PowerShell stack: $($_.ScriptStackTrace)"
    }

    Write-Error -Message "Runbook failed during step '$currentStep'. Review the structured log entries above." -ErrorAction Continue
    throw
}
