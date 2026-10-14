/**
 * Administrator endpoints: query student fee details and update fee records.
 *
 *   GET   /api/students?status=Overdue&page=1   one page of 50, optionally by status
 *   PATCH /api/students/{id}                    change totalFee, paidAmount and/or dueDate
 *
 * The caller needs the FeeAdmin role in their token AND a row in the Administrators table.
 * (The routes cannot start with "admin": Azure Functions reserves that prefix for its own admin API.)
 */
import { app, type HttpRequest, type HttpResponseInit, type InvocationContext } from '@azure/functions';
import { authenticate, requireAnyRole, type Caller } from '../lib/auth.ts';
import { readSettings } from '../lib/config.ts';
import { forbidden, notFound, unprocessable } from '../lib/errors.ts';
import { computeFee, dateKey, todayIn, toPaise, toRupees } from '../lib/fee.ts';
import { ok, parseId, parseWith, readJsonBody, withErrorHandling } from '../lib/http.ts';
import { createLogger, type Logger } from '../lib/logger.ts';
import { listStudentsQuerySchema, updateFeeSchema } from '../lib/schemas.ts';
import { getStudent, isAdministrator, listStudents, PAGE_SIZE, updateFees, type StudentRow } from '../lib/students.ts';

async function requireFeeAdmin(request: HttpRequest, log: Logger): Promise<Caller> {
  const caller = await authenticate(request);
  requireAnyRole(caller, 'FeeAdmin');
  if (!(await isAdministrator(caller.oid, log))) throw forbidden('Your account is not in the Administrators table.');
  return caller;
}

function toStudentFee(row: StudentRow, today: string) {
  return { studentId: row.StudentID, name: row.Name, course: row.Course, ...computeFee(row, today) };
}

export async function listStudentsHandler(request: HttpRequest, context: InvocationContext): Promise<HttpResponseInit> {
  const log = createLogger(context);
  await requireFeeAdmin(request, log);
  const query = parseWith(listStudentsQuerySchema, Object.fromEntries(request.query.entries()), 'query string');
  const page = query.page ?? 1;

  const today = todayIn(readSettings().feeTimeZone);
  const result = await listStudents(query.status, today, page, log);
  return ok({
    asOf: today,
    status: query.status ?? 'all',
    page,
    pageSize: PAGE_SIZE,
    total: result.total,
    students: result.rows.map((row) => toStudentFee(row, today)),
  });
}

export async function updateStudentHandler(request: HttpRequest, context: InvocationContext): Promise<HttpResponseInit> {
  const log = createLogger(context);
  await requireFeeAdmin(request, log);
  const studentId = parseId(request.params.id);
  const body = parseWith(updateFeeSchema, await readJsonBody(request), 'request body');

  const current = await getStudent(studentId, log);
  if (!current) throw notFound(`No student has id ${studentId}.`);

  // Fields not sent keep their current value. All comparisons are in whole paise.
  const totalPaise = toPaise(body.totalFee ?? current.TotalFee);
  const paidPaise = toPaise(body.paidAmount ?? current.PaidAmount);
  if (paidPaise > totalPaise) {
    throw unprocessable('Overpayment', 'paidAmount cannot be more than totalFee.', [
      { field: 'paidAmount', issue: `must be at most ${toRupees(totalPaise)}` },
    ]);
  }

  const updated = await updateFees(studentId, { totalPaise, paidPaise, dueDate: body.dueDate ?? dateKey(current.DueDate) }, log);
  if (!updated) throw notFound(`No student has id ${studentId}.`);
  log.info('student.updated', { studentId });

  const today = todayIn(readSettings().feeTimeZone);
  return ok({ ...toStudentFee(updated, today), asOf: today });
}

app.http('adminListStudents', {
  methods: ['GET'],
  authLevel: 'function',
  route: 'students',
  handler: withErrorHandling(listStudentsHandler),
});

app.http('adminUpdateStudent', {
  methods: ['PATCH'],
  authLevel: 'function',
  route: 'students/{id}',
  handler: withErrorHandling(updateStudentHandler),
});
