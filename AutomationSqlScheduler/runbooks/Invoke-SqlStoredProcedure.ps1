<#
.SYNOPSIS
    Connects to Azure SQL Database using the Automation Account's User Assigned
    Managed Identity (Entra ID token auth, no secrets/passwords) and invokes a
    configured stored procedure that takes no parameters.

.DESCRIPTION
    Designed to run as an Azure Automation PowerShell 7.4 runbook.

    Required Automation Account variables (created by main.bicep as plain
    variables because none of these values are secrets):
        SqlServerFqdn         - e.g. myserver.database.windows.net
        SqlDatabaseName       - e.g. mydatabase
        StoredProcedureName   - e.g. dbo.usp_RunScheduledJob
        UamiClientId          - Client (application) ID of the User Assigned
                                 Managed Identity attached to this Automation
                                 Account (output "uamiClientId" from main.bicep)

    The stored procedure name is validated against a strict allow-list pattern
    (optional [schema].[name] with only letters, digits and underscores, each
    part starting with a letter or underscore) before being embedded into the
    T-SQL command text. Since Azure SQL/T-SQL does not support parameterized
    object identifiers (you cannot do EXEC @spName), and the requirement is a
    stored procedure with NO parameters, we build the EXEC statement using
    QUOTENAME() equivalents applied client-side (bracket-escaping each part)
    after validating the input, which is a safe and standard pattern for
    dynamic-but-trusted identifier composition. No user-supplied SQL parameter
    values are ever concatenated — only the procedure name components.

.NOTES
    Requires the "Az.Accounts" module in the Automation Account's PowerShell
    runtime environment (for Connect-AzAccount / Get-AzAccessToken).
    Uses the .NET System.Data.SqlClient assembly included with PowerShell
    directly for robust token-based authentication, avoiding a dependency on
    SqlServer/Invoke-Sqlcmd and its version-specific AccessToken behavior.
#>

#Requires -Version 7.4
#Requires -Modules Az.Accounts

$ErrorActionPreference = 'Stop'

function Get-RequiredAutomationVariable {
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )

    try {
        $value = Get-AutomationVariable -Name $Name -ErrorAction Stop
    }
    catch {
        throw "Unable to read required Automation Variable '$Name': $($_.Exception.Message)"
    }

    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Required Automation Variable '$Name' is missing or empty."
    }

    return $value
}

function Assert-ValidSqlIdentifierPart {
    <#
        Validates a single (unquoted) SQL identifier part: must start with a
        letter or underscore and contain only letters, digits and
        underscores. This intentionally rejects brackets, quotes, semicolons,
        spaces, comment sequences (--, /*) and any other characters that
        could enable SQL injection via the object name.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $Part
    )

    if ($Part -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        throw "Invalid SQL identifier part '$Part'. Only letters, digits and underscores are allowed, and it must start with a letter or underscore."
    }
}

function Get-SafeQualifiedProcedureName {
    <#
        Splits StoredProcedureName on '.', validates each part strictly, and
        returns a safely bracket-quoted, fully-qualified EXEC target, e.g.
        [dbo].[usp_RunScheduledJob]. Rejects anything with more than 2 parts,
        empty parts, or invalid characters.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )

    $trimmed = $Name.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        throw 'StoredProcedureName cannot be empty.'
    }

    $parts = $trimmed.Split('.')
    if ($parts.Count -gt 2 -or $parts.Count -lt 1) {
        throw "Invalid StoredProcedureName '$Name'. Expected format is 'procedure' or 'schema.procedure'."
    }

    foreach ($part in $parts) {
        Assert-ValidSqlIdentifierPart -Part $part
    }

    $quotedParts = $parts | ForEach-Object { '[{0}]' -f $_ }
    return ($quotedParts -join '.')
}

try {
    Write-Output 'Starting SQL scheduler runbook.'

    # Ensure no residual Azure context/credentials are cached/persisted
    # between jobs on the shared Automation sandbox.
    Disable-AzContextAutosave -Scope Process | Out-Null

    $sqlServer = Get-RequiredAutomationVariable -Name 'SqlServerFqdn'
    $sqlDatabase = Get-RequiredAutomationVariable -Name 'SqlDatabaseName'
    $procedureNameRaw = Get-RequiredAutomationVariable -Name 'StoredProcedureName'
    $uamiClientId = Get-RequiredAutomationVariable -Name 'UamiClientId'

    $safeProcedureName = Get-SafeQualifiedProcedureName -Name $procedureNameRaw
    $parsedClientId = [Guid]::Empty
    if (-not [Guid]::TryParse($uamiClientId, [ref] $parsedClientId)) {
        throw "Automation Variable 'UamiClientId' must contain a valid GUID."
    }

    Write-Output "Target: server='$sqlServer' database='$sqlDatabase' procedure='$safeProcedureName'."

    Write-Output "Authenticating with User Assigned Managed Identity (clientId ending '...$($uamiClientId.Substring($uamiClientId.Length - 4))')."
    $null = Connect-AzAccount -Identity -AccountId $uamiClientId

    # Request an Entra ID access token scoped to Azure SQL Database.
    $tokenObj = Get-AzAccessToken -ResourceUrl 'https://database.windows.net/'
    if ($null -eq $tokenObj -or [string]::IsNullOrWhiteSpace($tokenObj.Token)) {
        throw 'Failed to acquire an access token for https://database.windows.net/.'
    }

    # Az.Accounts >= 4.x returns a SecureString token; older versions return a
    # plain string. Normalize to a plain string only for the short-lived local
    # use needed by SqlConnection, and never write it to output/logs.
    if ($tokenObj.Token -is [System.Security.SecureString]) {
        $accessToken = [System.Net.NetworkCredential]::new('', $tokenObj.Token).Password
    }
    else {
        $accessToken = [string]$tokenObj.Token
    }

    $connectionStringBuilder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
    $connectionStringBuilder.DataSource = "tcp:$sqlServer,1433"
    $connectionStringBuilder.InitialCatalog = $sqlDatabase
    $connectionStringBuilder.Encrypt = $true
    $connectionStringBuilder.TrustServerCertificate = $false
    $connectionStringBuilder.ConnectTimeout = 30

    $connection = [System.Data.SqlClient.SqlConnection]::new($connectionStringBuilder.ConnectionString)
    $connection.AccessToken = $accessToken

    try {
        Write-Output 'Opening SQL connection using Entra ID access token...'
        $connection.Open()

        $command = $connection.CreateCommand()
        $command.CommandType = [System.Data.CommandType]::Text
        # $safeProcedureName has already been strictly validated and bracket-
        # quoted above; no user-controlled SQL parameter values are used, and
        # the procedure itself takes no parameters.
        $command.CommandText = "EXEC $safeProcedureName;"
        $command.CommandTimeout = 300

        Write-Output "Executing stored procedure '$safeProcedureName'..."
        $rowsAffected = $command.ExecuteNonQuery()
        Write-Output "Stored procedure executed successfully. Rows affected: $rowsAffected."
    }
    finally {
        if ($connection.State -eq [System.Data.ConnectionState]::Open) {
            $connection.Close()
        }
        $connection.Dispose()
    }

    Write-Output 'SQL scheduler runbook completed successfully.'
}
catch {
    throw "SQL scheduler runbook failed: $($_.Exception.Message)"
}
