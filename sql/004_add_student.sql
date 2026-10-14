-- 004_add_student.sql: add one student who can sign in, all values via -v:
--   Name, Course, TotalFee, PaidAmount, DueDate (YYYY-MM-DD), Email, EntraObjectId
-- A past DueDate with PaidAmount < TotalFee makes the student overdue, so the next Logic App run emails them.
-- Every variable sits inside quotes and is converted in SQL, so the file is also valid T-SQL
-- for editors that don't run sqlcmd.
SET NOCOUNT ON;

INSERT INTO dbo.Students (Name, Course, TotalFee, PaidAmount, DueDate, Email, EntraObjectId)
VALUES (N'$(Name)', N'$(Course)',
        CAST(N'$(TotalFee)' AS DECIMAL(10,2)), CAST(N'$(PaidAmount)' AS DECIMAL(10,2)),
        CAST(N'$(DueDate)' AS DATE), N'$(Email)', N'$(EntraObjectId)');

SELECT SCOPE_IDENTITY() AS NewStudentID;
