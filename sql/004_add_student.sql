-- 004_add_student.sql: add one student who can sign in (for example a reviewer), all values via -v:
--   Name, Course, TotalFee, PaidAmount, DueDate (YYYY-MM-DD), Email, EntraObjectId
-- A past DueDate with PaidAmount < TotalFee makes the student overdue, so the next Logic App run emails them.
SET NOCOUNT ON;

INSERT INTO dbo.Students (Name, Course, TotalFee, PaidAmount, DueDate, Email, EntraObjectId)
VALUES (N'$(Name)', N'$(Course)', $(TotalFee), $(PaidAmount), '$(DueDate)', N'$(Email)', N'$(EntraObjectId)');

SELECT SCOPE_IDENTITY() AS NewStudentID;
