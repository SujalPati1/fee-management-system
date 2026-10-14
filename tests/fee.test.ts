// Unit tests for the fee maths and input rules. Run with: npm test (Node's built-in test runner).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { computeFee, daysBetween, feeStatus, todayIn, toPaise, toRupees } from '../src/lib/fee.ts';
import { updateFeeSchema } from '../src/lib/schemas.ts';

const day = (iso: string) => new Date(`${iso}T00:00:00Z`); // what the SQL driver returns for a DATE

test('floats: 10000.10 - 10000.00 is exactly 0.10, not 0.1000000000003638', () => {
  assert.equal(10000.1 - 10000.0 === 0.1, false); // the problem
  assert.equal(computeFee({ TotalFee: 10000.1, PaidAmount: 10000.0, DueDate: day('2026-12-01') }, '2026-10-14').balance, '0.10');
});

test('floats: ten payments of 0.10 add up to exactly 1.00', () => {
  const paidPaise = Array.from({ length: 10 }, () => toPaise(0.1)).reduce((a, b) => a + b, 0);
  assert.equal(paidPaise, 100);
  assert.equal(feeStatus(toPaise(1.0), paidPaise, '2026-01-01', '2026-10-14'), 'Paid');
});

test('toPaise turns every 2-decimal amount the driver can return back into exact paise', () => {
  for (let paise = 0; paise <= 2_000_000; paise++) assert.equal(toPaise(paise / 100), paise);
  assert.equal(toPaise(99_999_999.99), 9_999_999_999); // DECIMAL(10,2) maximum
});

test('toRupees formats with two decimals using integer maths', () => {
  assert.equal(toRupees(0), '0.00');
  assert.equal(toRupees(1), '0.01');
  assert.equal(toRupees(1_000_010), '10000.10');
  assert.equal(toRupees(9_999_999_999), '99999999.99');
});

test('status: fully paid is Paid even when the due date has passed', () => {
  assert.equal(computeFee({ TotalFee: 85000, PaidAmount: 85000, DueDate: day('2026-06-30') }, '2026-10-14').status, 'Paid');
});

test('status: a full scholarship (0 of 0) is Paid', () => {
  assert.equal(computeFee({ TotalFee: 0, PaidAmount: 0, DueDate: day('2026-11-30') }, '2026-10-14').status, 'Paid');
});

test('status: one paisa short and past due is Overdue', () => {
  assert.equal(computeFee({ TotalFee: 99999.99, PaidAmount: 99999.98, DueDate: day('2026-07-31') }, '2026-10-14').status, 'Overdue');
});

test('status: nothing paid but not yet due is Partially Paid (only three statuses exist)', () => {
  assert.equal(computeFee({ TotalFee: 110000, PaidAmount: 0, DueDate: day('2027-01-15') }, '2026-10-14').status, 'Partially Paid');
});

test('status: due today is not yet overdue; due yesterday is', () => {
  assert.equal(feeStatus(5000_00, 0, '2026-10-15', '2026-10-15'), 'Partially Paid');
  assert.equal(feeStatus(5000_00, 0, '2026-10-14', '2026-10-15'), 'Overdue');
});

test('time zone: at 01:30 in India the date is already the next day, while UTC is not', () => {
  const instant = new Date('2026-10-14T20:00:00Z'); // 15 Oct 01:30 IST
  assert.equal(todayIn('UTC', instant), '2026-10-14');
  assert.equal(todayIn('Asia/Kolkata', instant), '2026-10-15');
});

test('a DATE from the driver keeps its calendar day', () => {
  assert.equal(computeFee({ TotalFee: 1, PaidAmount: 0, DueDate: day('2026-10-14') }, '2026-10-14').dueDate, '2026-10-14');
});

test('daysBetween counts whole days', () => {
  assert.equal(daysBetween('2026-09-30', '2026-10-14'), 14);
  assert.equal(daysBetween('2026-10-14', '2026-10-14'), 0);
});

test('input: amounts with more than 2 decimals, negatives and huge values are rejected', () => {
  for (const bad of [1.005, -5, 123_456_789.12, 1e21]) {
    assert.equal(updateFeeSchema.safeParse({ paidAmount: bad }).success, false, `accepted ${bad}`);
  }
});

test('input: valid amounts and dates are accepted', () => {
  for (const good of [0, 1.01, 15000, 15000.5, 99_999_999.99]) {
    assert.equal(updateFeeSchema.safeParse({ paidAmount: good }).success, true, `rejected ${good}`);
  }
  assert.equal(updateFeeSchema.safeParse({ dueDate: '2026-12-31' }).success, true);
});

test('input: text amounts, unknown fields, bad dates and empty bodies are rejected', () => {
  assert.equal(updateFeeSchema.safeParse({ paidAmount: '100' }).success, false);
  assert.equal(updateFeeSchema.safeParse({ email: 'x@example.com' }).success, false);
  assert.equal(updateFeeSchema.safeParse({ dueDate: '2026-13-01' }).success, false);
  assert.equal(updateFeeSchema.safeParse({ dueDate: '0026-10-01' }).success, false);
  assert.equal(updateFeeSchema.safeParse({}).success, false);
});
