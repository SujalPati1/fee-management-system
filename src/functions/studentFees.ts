/**
 * GET /api/students/{id}/fees  (fee details and payment status by StudentID)
 *
 * Who may call:
 *   Student   only for their own row: the token's oid must equal the row's EntraObjectId
 *   FeeAdmin  any row, if they are also listed in the Administrators table
 * A student asking for any other id gets 403, whether or not that id exists, so students cannot
 * discover which ids are in use. Only administrators are told 404.
 */
import { app, type HttpRequest, type HttpResponseInit, type InvocationContext } from '@azure/functions';
import { authenticate, requireAnyRole } from '../lib/auth.ts';
import { readSettings } from '../lib/config.ts';
import { forbidden, notFound } from '../lib/errors.ts';
import { computeFee, todayIn } from '../lib/fee.ts';
import { ok, parseId, withErrorHandling } from '../lib/http.ts';
import { createLogger } from '../lib/logger.ts';
import { getStudent, isAdministrator } from '../lib/students.ts';

export async function studentFeesHandler(request: HttpRequest, context: InvocationContext): Promise<HttpResponseInit> {
  const log = createLogger(context);
  const caller = await authenticate(request);
  requireAnyRole(caller, 'Student', 'FeeAdmin');
  const studentId = parseId(request.params.id);

  const isAdmin = caller.roles.includes('FeeAdmin') && (await isAdministrator(caller.oid, log));
  const student = await getStudent(studentId, log);

  if (!isAdmin) {
    const ownRow = caller.roles.includes('Student') && student?.EntraObjectId?.toLowerCase() === caller.oid;
    if (!ownRow) throw forbidden('You can only view your own fee record.');
  }
  if (!student) throw notFound(`No student has id ${studentId}.`);

  const today = todayIn(readSettings().feeTimeZone);
  return ok({
    studentId: student.StudentID,
    name: student.Name,
    course: student.Course,
    ...computeFee(student, today),
    asOf: today,
  });
}

app.http('studentFees', {
  methods: ['GET'],
  authLevel: 'function', // the function key is known only to API Management
  route: 'students/{id}/fees',
  handler: withErrorHandling(studentFeesHandler),
});
