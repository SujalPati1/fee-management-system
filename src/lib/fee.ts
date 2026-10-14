/**
 * Fee calculations. Every amount is handled in whole paise (integers), never as a rupee float:
 *   - the SQL driver returns DECIMAL(10,2) values as JavaScript floats (10000.1, not "10000.10"),
 *     so each one is converted exactly once with toPaise()
 *   - results go back out as exact strings such as "10000.10" with toRupees()
 * "Today" is the calendar date in the fee time zone (Asia/Kolkata), not the server's UTC date.
 */

export const FEE_STATUSES = ['Paid', 'Partially Paid', 'Overdue'] as const;
export type FeeStatus = (typeof FEE_STATUSES)[number];

/** A DECIMAL(10,2) value as read by the driver, as exact whole paise. 10000.1 -> 1000010. */
export function toPaise(rupees: number): number {
  return Math.round(rupees * 100);
}

/** Whole paise as an exact rupee string: 1000010 -> "10000.10". Uses integer maths only. */
export function toRupees(paise: number): string {
  const sign = paise < 0 ? '-' : '';
  const abs = Math.abs(paise);
  const rupees = (abs - (abs % 100)) / 100;
  return `${sign}${rupees}.${String(abs % 100).padStart(2, '0')}`;
}

/** The calendar date ("YYYY-MM-DD") in a time zone at a given moment. */
export function todayIn(timeZone: string, now: Date = new Date()): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' }).format(now);
}

/** A DATE column value from the driver (a Date at UTC midnight) as "YYYY-MM-DD". */
export function dateKey(date: Date): string {
  return date.toISOString().slice(0, 10);
}

/** Whole days from one "YYYY-MM-DD" date to another (negative when `to` is earlier). */
export function daysBetween(from: string, to: string): number {
  return Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86_400_000);
}

/**
 * There are exactly three statuses:
 *   Paid            nothing is owed
 *   Overdue         something is owed and the due date is before today
 *   Partially Paid  something is owed and the due date has not passed (this includes nothing paid yet)
 * Dates are "YYYY-MM-DD" strings, which compare correctly as text.
 */
export function feeStatus(totalPaise: number, paidPaise: number, dueDate: string, today: string): FeeStatus {
  if (paidPaise >= totalPaise) return 'Paid';
  return dueDate < today ? 'Overdue' : 'Partially Paid';
}

export interface FeeRow {
  TotalFee: number;
  PaidAmount: number;
  DueDate: Date;
}

export interface FeeSummary {
  totalFee: string;
  paidAmount: string;
  balance: string;
  dueDate: string;
  status: FeeStatus;
}

/** The fee figures and status for one student row, as of `today`. */
export function computeFee(row: FeeRow, today: string): FeeSummary {
  const totalPaise = toPaise(row.TotalFee);
  const paidPaise = toPaise(row.PaidAmount);
  const dueDate = dateKey(row.DueDate);
  return {
    totalFee: toRupees(totalPaise),
    paidAmount: toRupees(paidPaise),
    balance: toRupees(Math.max(totalPaise - paidPaise, 0)),
    dueDate,
    status: feeStatus(totalPaise, paidPaise, dueDate, today),
  };
}
