-- 006_link_student_login.sql: link an existing student row to a person's Entra login.
-- Variables (via -v): StudentID, Email, EntraObjectId (the guest's object ID in this tenant).
-- Every variable sits inside quotes and is converted in SQL, so the file is also valid T-SQL
-- for editors that don't run sqlcmd. Safe to re-run: the same values leave the row unchanged.
SET NOCOUNT ON;

DECLARE @StudentID INT = CAST(N'$(StudentID)' AS INT);

UPDATE dbo.Students
SET Email = N'$(Email)', EntraObjectId = N'$(EntraObjectId)'
WHERE StudentID = @StudentID;

IF @@ROWCOUNT = 0
    THROW 50000, N'006_link_student_login: no student with that StudentID', 1;

PRINT CONCAT(N'006_link_student_login: student ', @StudentID, N' linked');
