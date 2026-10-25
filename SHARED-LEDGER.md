# Shared booking expense ledger

Apply `supabase/shared-ledger.sql` after the vendor-commercial migration. Repeatable and transactional; no existing personal expenses are published or changed. RPCs reload the PostgREST schema cache.

Entry points: Payments & obligations → Shared expense ledger; team vendor booking → Shared expense ledger; collaborator workspace → Shared expense ledger (financial access required).

Connecting a booking is reviewed and unique by booking ID. The agreed amount, currency and payment schedule are captured from the frozen agreement, never marked paid automatically. Subsequent booking edits do not rewrite this snapshot. Cancellation preserves recorded liability and payment history.

Apply `supabase/expense-settlements.sql` after shared-ledger.sql to enable reviewed cancellation or renegotiation adjustments. The original agreed_total stays unchanged; nullable settlement_total holds the latest reviewed commitment. Amounts, comparisons, payment caps and reconciliation use the latest commitment. Adjustments require financial plus planning-write access, an unreconciled expense, the current revision, a reason and explicit vendor-agreement confirmation. Received refunds must be recorded before reducing a commitment below net payments. Zero settlements are supported after refunds. An append-only adjustment history captures previous/new totals, actor and reason. Changes never infer payments or modify the original schedule. The migration is repeatable and retains RPC grants.

Payments and received refunds are append-only records of external transactions, not payment processing. Refunds reference the original expense payment, cannot exceed its unrefunded amount or precede it. Payments cannot exceed the remaining agreed balance. All amounts use native currency with separate currency totals. Financial access is checked for every request; modifications additionally require planning write. Direct table access is revoked and RLS enabled. Team-wide audit messages contain no financial amounts or notes.

Project-row locks serialize writes with bookings and membership changes. Expense versions reject stale edits. Client UUID and exact request payload journals make uncertain retries safe. Reconciliation requires a settled balance and review note, locks new payments, and can be explicitly reopened with history. This phase does not automatically import personal budget records, send payment requests, charge cards or deliver emails.

Validation: shared-ledger.sql.test.cjs uses real PostgreSQL semantics via PGlite for permissions, retries, balances, refunds, revocation and reconciliation; shared-ledger.ui.test.cjs exercises mobile forms, currency grouping, retry keys, read-only views and dialog closure.

## Deadline reminders

Apply `supabase/expense-reminders.sql` after expense-settlements.sql. It extends the existing hourly planning-reminder job and inbox refresh, rather than creating another scheduler. Upcoming (next three days), due-today and overdue phases are deduplicated by recipient, expense, milestone, due date and phase. Net recorded payments cover the earliest due milestones first for reminder calculations; this is not a bank allocation or payment instruction. Amounts are omitted from notification text. Notice opening goes to the authorized expense in the shared ledger.

Only active project members with financial access are eligible. Reads, inbox counts and the existing opted-in email-summary counts recheck permissions, outstanding balance and deadline phase. Fully covered milestones, cancelled bookings, archived projects, reconciled expenses and changed settlement totals suppress obsolete notices. The migration preserves existing task, event, decision and chat behavior, email consent, and notification preferences. No email is sent during installation. SQL regression tests cover deduplication, revocation, partial payments/refunds, email consent, adjusted settlements and cancellation.

## Reviewed payment schedules

Apply `supabase/expense-schedules.sql` after expense-reminders.sql. Financial editors can replace up to 12 deadlines with a reason and explicit confirmation, or clear the schedule to stop date reminders. Nonempty schedules must total the current commitment, including recorded payments; net paid covers earliest dates first. Each update captures previous/new schedules and the reviewed commitment in an append-only restricted history. Expense revisions and exact client request keys protect concurrent edits and retries. Reconciled expenses must first be reopened; cancelled bookings cannot enable new schedules.

The deadline engine compares the reviewed schedule_total with the current settlement total. A later settlement change pauses reminders until dates are reviewed against that amount. Schedule changes never rewrite payments or the original quote. Superseded deadline notices disappear under existing live visibility checks. The ledger shows the schedule history only to authorized financial readers.

## Financial reports

Apply `supabase/financial-reports.sql`. The read-only report RPC requires current read and finance access and returns a single SQL-statement snapshot: native-currency totals, vendor/currency breakdowns, obligation rows and the payment/refund journal. Original agreements, reviewed commitments, gross payments, refunds, net paid and balances are separate. Cancelled bookings retain their outstanding recorded liabilities; personal finance records are not imported into reports. No exchange-rate conversion or cross-currency grand total is inferred.

Open Shared expense ledger → Financial reports. Document exports use the existing PDF/PNG/JPG/Word format chooser; separate obligation and payment CSVs retain numeric values and escape spreadsheet formulas in user-controlled text. Every download requests a fresh authorized snapshot. Downloaded copies are private documents controlled by the downloader; revoking team access blocks subsequent requests rather than retracting downloaded files. Reports do not send emails or perform payments. Tests cover native-currency arithmetic, refunds, settlements, permission revocation, spreadsheet injection, HTML escaping and mobile export behavior.

## Receipts and financial documents

Apply `supabase/expense-files.sql` after expense-reminders.sql. Open a shared expense → Receipts & documents. Financial editors can upload a PDF/JPEG/PNG/WebP through the existing quota-checked private file pipeline, then link it to the expense or one of its payments/refunds. Each expense supports twenty active documents. Financial readers can list and download; adding/removing requires planning-write as well. Documents may be added after reconciliation without changing recorded financial amounts.

File associations require the uploader's own existing object, an allowed stored MIME type and a non-deleting reservation. The project lock serializes attachment changes and the uploader's file advisory lock coordinates cleanup. Exact repeated links are idempotent; changed metadata on the same link requires a new reviewed action. Failed link retries reuse the verified upload. Removed links lose shared access immediately and retain cleanup protection for thirty days; reattaching the same document restores the link. Active links always protect the file from cleanup.

Storage RLS checks current project financial permissions before issuing download links. The UI rechecks the association and signs a link for sixty seconds, verifies the storage origin and downloads without embedding active document content. Already issued short-lived URLs and downloaded copies cannot be retracted; uploader ownership and sharing through other authorized records remain in force. Generic activity entries omit file names and payment details. This phase stores documents but does not OCR receipts or infer payments from their contents.
