-- 003_bulk_5000.sql: 5,000 generated students, to show the system handles at least 5,000 records.
-- None of them is overdue for at least a year after this script runs: each one is fully paid
-- or due one to three years later. After that the part-paid ones fall due one by one, so re-seed
-- (or pay them) before then. Their emails use example.com, a domain reserved for examples.
-- Safe to re-run: skipped if the bulk rows already exist.
SET NOCOUNT ON;

IF NOT EXISTS (SELECT 1 FROM dbo.Students WHERE Email LIKE N'bulk%@example.com')
BEGIN
    DECLARE @today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'India Standard Time' AS DATE);

    -- 10 digits crossed 4 times gives the numbers 1 to 10,000; keep 1 to 5,000.
    WITH digits AS (SELECT d FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) AS t(d)),
         numbers AS (
             SELECT a.d * 1000 + b.d * 100 + c.d * 10 + e.d + 1 AS n
             FROM digits a CROSS JOIN digits b CROSS JOIN digits c CROSS JOIN digits e
         )
    INSERT INTO dbo.Students (Name, Course, TotalFee, PaidAmount, DueDate, Email)
    SELECT
        CONCAT(N'Bulk Student ', RIGHT(CONCAT(N'000', n), 4)),
        CHOOSE(n % 4 + 1, N'B.Tech Computer Engineering', N'B.Tech Information Technology', N'B.Tech Electronics', N'MBA'),
        CAST(60000 + (n % 50) * 1000 AS DECIMAL(10,2)),                          -- 60,000 to 109,000
        CASE WHEN n % 3 = 0 THEN CAST(60000 + (n % 50) * 1000 AS DECIMAL(10,2)) -- every 3rd: fully paid
             ELSE 20000.00 END,                                                  -- the rest: part paid
        DATEADD(DAY, 365 + n % 730, @today),                                     -- 1 to 3 years ahead
        CONCAT(N'bulk', RIGHT(CONCAT(N'000', n), 4), N'@example.com')
    FROM numbers
    WHERE n <= 5000;

    PRINT CONCAT(N'003_bulk_5000: inserted ', @@ROWCOUNT, N' rows');
END
ELSE
    PRINT N'003_bulk_5000: bulk rows already exist, skipped';
