-- 001_schema.sql: tables, constraints and indexes.
-- Safe to re-run: every object is created only if it does not exist yet.
SET NOCOUNT ON;

-- Students: the six fee columns, plus Email (reminders) and EntraObjectId (login link).
IF OBJECT_ID(N'dbo.Students', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Students (
        StudentID     INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Students PRIMARY KEY,
        Name          NVARCHAR(100)    NOT NULL,
        Course        NVARCHAR(100)    NOT NULL,
        TotalFee      DECIMAL(10,2)    NOT NULL CONSTRAINT CK_Students_TotalFee CHECK (TotalFee >= 0),
        PaidAmount    DECIMAL(10,2)    NOT NULL CONSTRAINT DF_Students_PaidAmount DEFAULT (0),
        DueDate       DATE             NOT NULL,
        Email         NVARCHAR(254)    NOT NULL,
        EntraObjectId UNIQUEIDENTIFIER NULL,
        -- No negative payments and no overpayment (the API answers 422 first; this is the safety net).
        CONSTRAINT CK_Students_PaidAmount CHECK (PaidAmount >= 0 AND PaidAmount <= TotalFee)
    );
END;

-- Overdue query: WHERE DueDate < @today AND PaidAmount < TotalFee. The included columns
-- let SQL answer it from the index alone, without reading the table.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Students_DueDate' AND object_id = OBJECT_ID(N'dbo.Students'))
    CREATE INDEX IX_Students_DueDate ON dbo.Students (DueDate) INCLUDE (TotalFee, PaidAmount, Name, Email);

-- One login can belong to only one student; NULL (no login yet) is allowed many times.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_Students_EntraObjectId' AND object_id = OBJECT_ID(N'dbo.Students'))
    CREATE UNIQUE INDEX UX_Students_EntraObjectId ON dbo.Students (EntraObjectId) WHERE EntraObjectId IS NOT NULL;

-- Administrators: AdminID, Name and Role, plus EntraObjectId (login link).
IF OBJECT_ID(N'dbo.Administrators', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Administrators (
        AdminID       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Administrators PRIMARY KEY,
        Name          NVARCHAR(100)    NOT NULL,
        Role          NVARCHAR(50)     NOT NULL CONSTRAINT CK_Administrators_Role CHECK (Role = N'FeeAdmin'),
        EntraObjectId UNIQUEIDENTIFIER NULL
    );
END;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_Administrators_EntraObjectId' AND object_id = OBJECT_ID(N'dbo.Administrators'))
    CREATE UNIQUE INDEX UX_Administrators_EntraObjectId ON dbo.Administrators (EntraObjectId) WHERE EntraObjectId IS NOT NULL;

PRINT N'001_schema: done';
