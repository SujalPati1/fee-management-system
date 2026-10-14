-- 006_link_student_login.sql: link an existing student row to a person's Entra login.
-- Variables (via -v): StudentID, Email, EntraObjectId (the guest's object ID in this tenant).
-- Safe to re-run: the same values leave the row unchanged.
SET NOCOUNT ON;

UPDATE dbo.Students
SET Email = N'$(Email)', EntraObjectId = N'$(EntraObjectId)'
WHERE StudentID = $(StudentID);

IF @@ROWCOUNT = 0
    THROW 50000, N'006_link_student_login: no student with that StudentID', 1;

PRINT N'006_link_student_login: student $(StudentID) linked';
