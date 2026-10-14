-- 005_grant_function.sql: lets the Function App's managed identity into the database.
-- Least privilege: it can read both tables but change only the three fee columns.
-- Variable: FunctionAppName (the identity has the same name as the Function App).
-- Safe to re-run.
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$(FunctionAppName)')
    CREATE USER [$(FunctionAppName)] FROM EXTERNAL PROVIDER;

GRANT SELECT ON dbo.Students TO [$(FunctionAppName)];
GRANT UPDATE (TotalFee, PaidAmount, DueDate) ON dbo.Students TO [$(FunctionAppName)];
GRANT SELECT ON dbo.Administrators TO [$(FunctionAppName)];

PRINT N'005_grant_function: done';
