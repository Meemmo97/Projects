/*
================================================================================
 bootstrap-uami-db-user.sql

 Run this script manually while connected to the TARGET Azure SQL database
 (not master) as the configured Microsoft Entra administrator, or as a
 principal with equivalent permission to create external users and grant
 object permissions.

 deploy.ps1 intentionally NEVER runs this data-plane bootstrap.

 Configure only the values in the block below:
   @UamiDisplayName  - exact Azure UAMI resource/display name
   @UamiClientId     - UAMI clientId (main.bicep output uamiClientId)
   @SchemaName       - stored procedure schema
   @ProcedureName    - stored procedure name
   @UseSidFallback   - 0: CREATE USER FROM EXTERNAL PROVIDER (preferred)
                       1: CREATE USER WITH SID, TYPE = E

 The SID fallback avoids a Microsoft Graph lookup by Azure SQL when the server
 cannot resolve the UAMI. For applications and managed identities Azure SQL
 requires the application/client ID (not the principal/object ID) as SID. The
 script converts the client ID to UNIQUEIDENTIFIER first and then to
 VARBINARY(16); converting GUID text directly to binary would be incorrect.
================================================================================
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @UamiDisplayName sysname = N'id-sql-scheduler-dev';
DECLARE @UamiClientId nvarchar(36) = N'00000000-0000-0000-0000-000000000000';
DECLARE @SchemaName sysname = N'dbo';
DECLARE @ProcedureName sysname = N'usp_RunScheduledJob';
DECLARE @UseSidFallback bit = 0;

IF DB_NAME() = N'master'
BEGIN
    THROW 50001, 'Connect to the target application database, not master.', 1;
END;

IF NULLIF(LTRIM(RTRIM(@UamiDisplayName)), N'') IS NULL
    OR NULLIF(LTRIM(RTRIM(@SchemaName)), N'') IS NULL
    OR NULLIF(LTRIM(RTRIM(@ProcedureName)), N'') IS NULL
BEGIN
    THROW 50002, 'UAMI, schema, and procedure names must not be empty.', 1;
END;

DECLARE @QualifiedProcedure nvarchar(517) =
    QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@ProcedureName);

DECLARE @ClientGuid uniqueidentifier =
    TRY_CONVERT(uniqueidentifier, @UamiClientId);

IF @ClientGuid IS NULL
   OR @ClientGuid = '00000000-0000-0000-0000-000000000000'
BEGIN
    THROW 50004, 'Set @UamiClientId to the non-zero UAMI clientId output by the Bicep deployment.', 1;
END;

DECLARE @ExpectedSid varbinary(16) =
    CONVERT(varbinary(16), @ClientGuid);

IF NOT EXISTS
(
    SELECT 1
    FROM sys.objects
    WHERE object_id = OBJECT_ID(@QualifiedProcedure)
      AND type IN (N'P', N'PC')
)
BEGIN
    THROW 50003, 'The configured stored procedure does not exist in this database.', 1;
END;

IF NOT EXISTS
(
    SELECT 1
    FROM sys.database_principals
    WHERE name = @UamiDisplayName
)
BEGIN
    DECLARE @CreateUserSql nvarchar(max);

    IF @UseSidFallback = 0
    BEGIN
        /*
          Preferred approach. Azure SQL resolves the UAMI by display name
          through Microsoft Graph. The SQL logical server identity / executing
          Entra admin must be able to perform that lookup.
        */
        SET @CreateUserSql =
            N'CREATE USER ' + QUOTENAME(@UamiDisplayName)
            + N' FROM EXTERNAL PROVIDER;';
    END;
    ELSE
    BEGIN
        /*
          Reliable fallback when Graph resolution is unavailable. TYPE = E
          creates an external Entra user. The SID is the UAMI application/client
          ID encoded as the 16-byte representation of a UNIQUEIDENTIFIER.
        */
        DECLARE @SidHex varchar(34) =
            sys.fn_varbintohexstr(@ExpectedSid);

        SET @CreateUserSql =
            N'CREATE USER ' + QUOTENAME(@UamiDisplayName)
            + N' WITH SID = ' + @SidHex + N', TYPE = E;';
    END;

    EXEC sys.sp_executesql @CreateUserSql;
END;

IF NOT EXISTS
(
    SELECT 1
    FROM sys.database_principals
    WHERE name = @UamiDisplayName
      AND type = N'E'
      AND sid = @ExpectedSid
)
BEGIN
    THROW 50005, 'A database principal with this name exists, but it is not the configured UAMI clientId. No permission was granted.', 1;
END;

/*
  Least privilege: grant EXECUTE on this one stored procedure only. No
  database role membership and no database-, schema-, or server-level grant.
  Re-running the GRANT is safe and preserves the intended permission.
*/
DECLARE @GrantSql nvarchar(max) =
    N'GRANT EXECUTE ON OBJECT::' + @QualifiedProcedure
    + N' TO ' + QUOTENAME(@UamiDisplayName) + N';';

EXEC sys.sp_executesql @GrantSql;

SELECT
    DB_NAME() AS database_name,
    dp.name AS principal_name,
    dp.type_desc,
    dp.authentication_type_desc,
    OBJECT_SCHEMA_NAME(perm.major_id) AS procedure_schema,
    OBJECT_NAME(perm.major_id) AS procedure_name,
    perm.permission_name,
    perm.state_desc
FROM sys.database_principals AS dp
LEFT JOIN sys.database_permissions AS perm
    ON perm.grantee_principal_id = dp.principal_id
    AND perm.major_id = OBJECT_ID(@QualifiedProcedure)
    AND perm.permission_name = N'EXECUTE'
WHERE dp.name = @UamiDisplayName;

/*
  Decommissioning example (review before executing):

  REVOKE EXECUTE ON OBJECT::[dbo].[usp_RunScheduledJob]
      FROM [id-sql-scheduler-dev];
  DROP USER [id-sql-scheduler-dev];
*/
