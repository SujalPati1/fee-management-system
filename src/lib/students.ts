/**
 * Every SQL query the endpoints run. All values are passed as typed parameters (never pasted into
 * the SQL text), so input can never change a query. Fee figures and statuses are worked out in
 * fee.ts from these rows; SQL only stores, filters and pages.
 */
import { withDatabase, sql, type DatabaseCallOptions } from './db.ts';
import type { FeeStatus } from './fee.ts';
import type { Logger } from './logger.ts';

export interface StudentRow {
  StudentID: number;
  Name: string;
  Course: string;
  TotalFee: number;
  PaidAmount: number;
  DueDate: Date;
  Email: string;
  EntraObjectId: string | null;
}

export const PAGE_SIZE = 50;

/** "YYYY-MM-DD" as the Date the driver expects for a DATE parameter (UTC midnight, never shifted). */
const asSqlDate = (day: string) => new Date(`${day}T00:00:00Z`);

const reads = (log: Logger): DatabaseCallOptions => ({ idempotent: true, log });

export async function getStudent(studentId: number, log: Logger): Promise<StudentRow | undefined> {
  const result = await withDatabase(
    (pool) =>
      pool
        .request()
        .input('id', sql.Int, studentId)
        .query<StudentRow>(
          `SELECT StudentID, Name, Course, TotalFee, PaidAmount, DueDate, Email, EntraObjectId
           FROM dbo.Students WHERE StudentID = @id`,
        ),
    reads(log),
  );
  return result.recordset[0];
}

/** True when this Entra object ID belongs to a row in the Administrators table. */
export async function isAdministrator(oid: string, log: Logger): Promise<boolean> {
  const result = await withDatabase(
    (pool) =>
      pool
        .request()
        .input('oid', sql.UniqueIdentifier, oid)
        .query('SELECT 1 AS found FROM dbo.Administrators WHERE EntraObjectId = @oid'),
    reads(log),
  );
  return result.recordset.length > 0;
}

export interface StudentPage {
  total: number;
  rows: StudentRow[];
}

/**
 * One page of students, optionally filtered by status as of `today`. The WHERE clause is the
 * same rule as feeStatus() in fee.ts, written as a filter so that paging works on the database.
 */
export async function listStudents(status: FeeStatus | undefined, today: string, page: number, log: Logger): Promise<StudentPage> {
  const result = await withDatabase(
    (pool) =>
      pool
        .request()
        .input('status', sql.NVarChar(20), status ?? null)
        .input('today', sql.Date, asSqlDate(today))
        .input('offset', sql.Int, (page - 1) * PAGE_SIZE)
        .input('pageSize', sql.Int, PAGE_SIZE)
        .query<StudentRow & { Total: number }>(
          `SELECT StudentID, Name, Course, TotalFee, PaidAmount, DueDate, Email, EntraObjectId,
                  COUNT(*) OVER () AS Total
           FROM dbo.Students
           WHERE @status IS NULL
              OR (@status = N'Paid'           AND PaidAmount >= TotalFee)
              OR (@status = N'Overdue'        AND PaidAmount <  TotalFee AND DueDate <  @today)
              OR (@status = N'Partially Paid' AND PaidAmount <  TotalFee AND DueDate >= @today)
           ORDER BY StudentID
           OFFSET @offset ROWS FETCH NEXT @pageSize ROWS ONLY
           OPTION (RECOMPILE)`,
        ),
    reads(log),
  );
  return { total: result.recordset[0]?.Total ?? 0, rows: result.recordset };
}

export interface FeeUpdate {
  totalPaise: number;
  paidPaise: number;
  dueDate: string;
}

/**
 * Sets the three fee columns and returns the updated row (undefined if the student is gone).
 * Setting fixed values is idempotent, so it is safe to retry while the database wakes up.
 * The CHECK constraint still stops an overpayment if two admins update the same row at once.
 */
export async function updateFees(studentId: number, update: FeeUpdate, log: Logger): Promise<StudentRow | undefined> {
  const result = await withDatabase(
    (pool) =>
      pool
        .request()
        .input('id', sql.Int, studentId)
        .input('totalFee', sql.Decimal(10, 2), update.totalPaise / 100)
        .input('paidAmount', sql.Decimal(10, 2), update.paidPaise / 100)
        .input('dueDate', sql.Date, asSqlDate(update.dueDate))
        .query<StudentRow>(
          `UPDATE dbo.Students
           SET TotalFee = @totalFee, PaidAmount = @paidAmount, DueDate = @dueDate
           OUTPUT inserted.StudentID, inserted.Name, inserted.Course, inserted.TotalFee, inserted.PaidAmount,
                  inserted.DueDate, inserted.Email, inserted.EntraObjectId
           WHERE StudentID = @id`,
        ),
    { idempotent: true, log },
  );
  return result.recordset[0];
}

export type OverdueRow = Pick<StudentRow, 'StudentID' | 'Name' | 'Email' | 'TotalFee' | 'PaidAmount' | 'DueDate'>;

/**
 * Everyone overdue as of `today` (the Logic App's reminder list). Only columns held in
 * IX_Students_DueDate are selected, so SQL answers from the index without reading the table.
 */
export async function listOverdue(today: string, log: Logger): Promise<OverdueRow[]> {
  const result = await withDatabase(
    (pool) =>
      pool
        .request()
        .input('today', sql.Date, asSqlDate(today))
        .query<OverdueRow>(
          `SELECT StudentID, Name, Email, TotalFee, PaidAmount, DueDate
           FROM dbo.Students
           WHERE DueDate < @today AND PaidAmount < TotalFee
           ORDER BY DueDate, StudentID`,
        ),
    reads(log),
  );
  return result.recordset;
}
