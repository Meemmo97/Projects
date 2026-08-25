/*
  Workload-specific Azure SQL permissions for:
    UAMI:       prod-uami01-lightmes-e74gj
    Client ID:  6ca2a520-2159-403d-bf01-6a7a9aefce0e
    Database:   prod-db01-lightmes-e74gj

  Run manually while connected to the target database as an authorized
  database administrator. deploy.ps1 never executes this script.

  ALTER is intentionally granted on all three workload objects as requested.
  This is broader than DML and permits structural changes to those objects.
  OperationsManaged requires ALTER when sp_SplitOrder executes TRUNCATE TABLE.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ExpectedDatabase sysname = N'prod-db01-lightmes-e74gj';
DECLARE @UamiName sysname = N'prod-uami01-lightmes-e74gj';
DECLARE @UamiClientId uniqueidentifier =
    '6ca2a520-2159-403d-bf01-6a7a9aefce0e';
DECLARE @ExpectedSid varbinary(16) =
    CONVERT(varbinary(16), @UamiClientId);

IF DB_NAME() <> @ExpectedDatabase
BEGIN
    THROW 50001, 'Connect to prod-db01-lightmes-e74gj before running this script.', 1;
END;

IF NOT EXISTS
(
    SELECT 1
    FROM sys.database_principals
    WHERE name = @UamiName
)
BEGIN
    DECLARE @SidHex varchar(34) =
        sys.fn_varbintohexstr(@ExpectedSid);

    DECLARE @CreateUserSql nvarchar(max) =
        N'CREATE USER ' + QUOTENAME(@UamiName)
        + N' WITH SID = ' + @SidHex + N', TYPE = E;';

    EXEC sys.sp_executesql @CreateUserSql;
END;

IF NOT EXISTS
(
    SELECT 1
    FROM sys.database_principals
    WHERE name = @UamiName
      AND type = N'E'
      AND sid = @ExpectedSid
)
BEGIN
    THROW 50002, 'The database principal exists but does not match the configured UAMI client ID.', 1;
END;

IF OBJECT_ID(N'dbo.sp_SplitOrder', N'P') IS NULL
BEGIN
    THROW 50003, 'Stored procedure dbo.sp_SplitOrder does not exist.', 1;
END;

IF OBJECT_ID(N'dbo.sp_STD_DateMin', N'P') IS NULL
BEGIN
    THROW 50004, 'Stored procedure dbo.sp_STD_DateMin does not exist.', 1;
END;

IF OBJECT_ID(N'dbo.Shifts') IS NULL
BEGIN
    THROW 50005, 'Object dbo.Shifts does not exist.', 1;
END;

IF OBJECT_ID(N'dbo.OperationsManaged') IS NULL
BEGIN
    THROW 50006, 'Object dbo.OperationsManaged does not exist.', 1;
END;

IF OBJECT_ID(N'dbo.vv_Operations') IS NULL
BEGIN
    THROW 50007, 'Object dbo.vv_Operations does not exist.', 1;
END;

DECLARE @Principal nvarchar(258) = QUOTENAME(@UamiName);
DECLARE @GrantSql nvarchar(max) =
    N'GRANT EXECUTE ON OBJECT::[dbo].[sp_SplitOrder] TO ' + @Principal + N';'
    + N'GRANT EXECUTE ON OBJECT::[dbo].[sp_STD_DateMin] TO ' + @Principal + N';'
    + N'GRANT SELECT, INSERT, UPDATE, DELETE, ALTER '
    + N'ON OBJECT::[dbo].[Shifts] TO ' + @Principal + N';'
    + N'GRANT SELECT, INSERT, UPDATE, DELETE, ALTER '
    + N'ON OBJECT::[dbo].[OperationsManaged] TO ' + @Principal + N';'
    + N'GRANT SELECT, INSERT, UPDATE, DELETE, ALTER '
    + N'ON OBJECT::[dbo].[vv_Operations] TO ' + @Principal + N';';

EXEC sys.sp_executesql @GrantSql;

/*
  Remove the temporary diagnostic membership after the object-level grants
  have been established. This is idempotent when the user is not db_owner.
*/
IF IS_ROLEMEMBER(N'db_owner', @UamiName) = 1
BEGIN
    DECLARE @DropDbOwnerSql nvarchar(max) =
        N'ALTER ROLE [db_owner] DROP MEMBER ' + @Principal + N';';

    EXEC sys.sp_executesql @DropDbOwnerSql;
END;

SELECT
    principal.name AS principal_name,
    permission.permission_name,
    permission.state_desc,
    OBJECT_SCHEMA_NAME(permission.major_id) AS object_schema,
    OBJECT_NAME(permission.major_id) AS object_name
FROM sys.database_permissions AS permission
JOIN sys.database_principals AS principal
    ON principal.principal_id = permission.grantee_principal_id
WHERE principal.name = @UamiName
ORDER BY object_schema, object_name, permission.permission_name;
