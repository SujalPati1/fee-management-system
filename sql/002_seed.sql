-- 002_seed.sql: 20 hand-made students covering every status, plus the administrators.
-- Personal details are sqlcmd variables passed with -v, so they are never committed:
--   OwnerEmail, Student1Email, Student2Email, AdminName, AdminObjectId
-- Reminders only ever reach inboxes you own: every student uses one of the three emails.
-- Dates assume the build started on 2026-10-14 ("past" = before it, "future" = after it).
-- Safe to re-run: rows are inserted only into empty tables.
SET NOCOUNT ON;

IF NOT EXISTS (SELECT 1 FROM dbo.Students)
BEGIN
    INSERT INTO dbo.Students (Name, Course, TotalFee, PaidAmount, DueDate, Email) VALUES
    -- Overdue: due date passed, not fully paid
    (N'Rohan Kulkarni',   N'B.Tech Computer Engineering',   120000.00,  60000.00, '2026-09-30', N'$(Student1Email)'), -- guest student 1
    (N'Neha Joshi',       N'B.Tech Information Technology',  98000.00,      0.00, '2026-08-31', N'$(OwnerEmail)'),    -- nothing paid
    (N'Aditya Rane',      N'B.Tech Electronics',             99999.99,  99999.98, '2026-07-31', N'$(OwnerEmail)'),    -- one paisa short
    (N'Kavya Iyer',       N'MBA',                            10000.10,  10000.00, '2026-10-01', N'$(OwnerEmail)'),    -- balance 0.10 (float trap)
    -- Paid: fully paid, whatever the due date
    (N'Isha Deshmukh',    N'B.Tech Information Technology', 115000.00, 115000.00, '2026-09-15', N'$(Student2Email)'), -- guest student 2
    (N'Vikram Shetty',    N'B.Tech Computer Engineering',    85000.00,  85000.00, '2026-06-30', N'$(OwnerEmail)'),    -- past due but paid: not overdue
    (N'Ananya Pillai',    N'B.Tech Electronics',                 0.00,      0.00, '2026-11-30', N'$(OwnerEmail)'),    -- full scholarship
    (N'Karan Malhotra',   N'MBA',                            72000.50,  72000.50, '2027-03-31', N'$(OwnerEmail)'),    -- paid early
    (N'Sneha Patwardhan', N'B.Tech Computer Engineering',    99999.99,  99999.99, '2026-08-15', N'$(OwnerEmail)'),    -- paid to the paisa
    -- Partially Paid: due date not passed yet (includes nothing paid)
    (N'Arjun Nair',       N'B.Tech Mechanical Engineering', 110000.00,      0.00, '2027-01-15', N'$(OwnerEmail)'),    -- nothing paid yet
    (N'Pooja Gupta',      N'B.Tech Information Technology',  95000.00,  45000.25, '2026-12-31', N'$(OwnerEmail)'),
    (N'Siddharth Bose',   N'B.Tech Electronics',             50000.00,  49999.99, '2026-11-30', N'$(OwnerEmail)'),    -- one paisa short, not due
    (N'Meera Kapoor',     N'MBA',                           150000.00, 100000.00, '2027-02-28', N'$(OwnerEmail)'),
    (N'Rahul Verma',      N'B.Tech Civil Engineering',       88000.00,  22000.00, '2027-03-31', N'$(OwnerEmail)'),
    (N'Tanvi Sawant',     N'B.Tech Computer Engineering',   120000.00, 119000.00, '2026-12-15', N'$(OwnerEmail)'),
    (N'Nikhil Chavan',    N'B.Tech Mechanical Engineering', 105000.00,  50000.00, '2027-01-31', N'$(OwnerEmail)'),
    (N'Riya Sharma',      N'B.Tech Civil Engineering',       92000.00,  30000.00, '2027-02-15', N'$(OwnerEmail)'),
    (N'Omkar Jadhav',     N'MBA',                           140000.00,  70000.00, '2026-12-01', N'$(OwnerEmail)'),
    (N'Divya Menon',      N'B.Tech Information Technology', 100000.00,      0.01, '2027-03-15', N'$(OwnerEmail)'),    -- one paisa paid
    (N'Yash Thakur',      N'B.Tech Electronics',             75000.00,  25000.00, '2027-01-10', N'$(OwnerEmail)');
END
ELSE
    PRINT N'002_seed: Students already has rows, skipped';

IF NOT EXISTS (SELECT 1 FROM dbo.Administrators)
BEGIN
    INSERT INTO dbo.Administrators (Name, Role, EntraObjectId) VALUES
    (N'$(AdminName)',    N'FeeAdmin', N'$(AdminObjectId)'), -- you: can sign in
    (N'Accounts Office', N'FeeAdmin', NULL);                -- record only, no login
END
ELSE
    PRINT N'002_seed: Administrators already has rows, skipped';

PRINT N'002_seed: done';
