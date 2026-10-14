/**
 * GET /api/reminders/overdue  (the students with overdue payments, for the reminder emails)
 *
 * Called by the Logic App with its managed identity, whose token carries the Reminders.Read role.
 * That role can only be given to applications, so no person (not even a FeeAdmin) can call this.
 * The Logic App only sends the emails; which students are overdue, and by how much, is decided here.
 */
import { app, type HttpRequest, type HttpResponseInit, type InvocationContext } from '@azure/functions';
import { authenticate, requireAnyRole } from '../lib/auth.ts';
import { readSettings } from '../lib/config.ts';
import { dateKey, daysBetween, todayIn, toPaise, toRupees } from '../lib/fee.ts';
import { ok, withErrorHandling } from '../lib/http.ts';
import { createLogger } from '../lib/logger.ts';
import { listOverdue } from '../lib/students.ts';

export async function overdueHandler(request: HttpRequest, context: InvocationContext): Promise<HttpResponseInit> {
  const log = createLogger(context);
  const caller = await authenticate(request);
  requireAnyRole(caller, 'Reminders.Read');

  const today = todayIn(readSettings().feeTimeZone);
  const rows = await listOverdue(today, log);
  log.info('reminders.listed', { count: rows.length });

  return ok({
    asOf: today,
    count: rows.length,
    students: rows.map((row) => {
      const dueDate = dateKey(row.DueDate);
      return {
        studentId: row.StudentID,
        name: row.Name,
        email: row.Email,
        balance: toRupees(toPaise(row.TotalFee) - toPaise(row.PaidAmount)),
        dueDate,
        daysOverdue: daysBetween(dueDate, today),
      };
    }),
  });
}

app.http('remindersOverdue', {
  methods: ['GET'],
  authLevel: 'function',
  route: 'reminders/overdue',
  handler: withErrorHandling(overdueHandler),
});
