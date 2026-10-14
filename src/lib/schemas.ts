/**
 * Input rules (zod). Each schema gives runtime validation and the TypeScript type of the result.
 */
import { z } from 'zod';
import { FEE_STATUSES } from './fee.ts';

const MAX_AMOUNT = 99_999_999.99; // largest DECIMAL(10,2) value

// JSON numbers print in their shortest exact form, so a value typed with at most two decimals
// always prints with at most two. Checking the text rejects 1.005 (SQL would silently round it
// to 1.01) and forms such as 1e21 or negative numbers.
const amountSchema = z
  .number()
  .max(MAX_AMOUNT, 'is too large')
  .refine((value) => /^\d+(\.\d{1,2})?$/.test(String(value)), 'must be 0 or more with at most 2 decimal places');

// ISO dates compare correctly as text. The range keeps typos such as 0026-10-01 out.
const dueDateSchema = z.iso
  .date('must be a date in YYYY-MM-DD format')
  .refine((value) => value >= '2000-01-01' && value <= '2099-12-31', 'must be between 2000-01-01 and 2099-12-31');

/** PATCH /api/students/{id}: only the three fee fields; unknown fields are rejected. */
export const updateFeeSchema = z
  .strictObject({
    totalFee: amountSchema.optional(),
    paidAmount: amountSchema.optional(),
    dueDate: dueDateSchema.optional(),
  })
  .refine((body) => Object.keys(body).length > 0, 'provide at least one of totalFee, paidAmount, dueDate');

export type UpdateFeeInput = z.infer<typeof updateFeeSchema>;

/** GET /api/students?status=&page= */
export const listStudentsQuerySchema = z.strictObject({
  status: z.enum(FEE_STATUSES).optional(),
  page: z
    .string()
    .regex(/^\d{1,6}$/, 'must be a whole number')
    .transform(Number)
    .refine((page) => page >= 1, 'must be 1 or more')
    .optional(),
});
