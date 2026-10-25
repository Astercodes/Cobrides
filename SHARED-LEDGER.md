# Shared booking expense ledger

Apply `supabase/shared-ledger.sql` after the vendor-commercial migration. Repeatable and transactional; no existing personal expenses are published or changed. RPCs reload the PostgREST schema cache.

Entry points: Payments & obligations → Shared expense ledger; team vendor booking → Shared expense ledger; collaborator workspace → Shared expense ledger (financial access required).

Connecting a booking is reviewed and unique by booking ID. The agreed amount, currency and payment schedule are captured from the frozen agreement, never marked paid automatically. Subsequent booking edits do not rewrite this snapshot. Cancellation preserves recorded liability and payment history. Revised cancellation settlements are not inferred; a future explicit adjustment workflow can handle renegotiated liabilities.

Payments and received refunds are append-only records of external transactions, not payment processing. Refunds reference the original expense payment, cannot exceed its unrefunded amount or precede it. Payments cannot exceed the remaining agreed balance. All amounts use native currency with separate currency totals. Financial access is checked for every request; modifications additionally require planning write. Direct table access is revoked and RLS enabled. Team-wide audit messages contain no financial amounts or notes.

Project-row locks serialize writes with bookings and membership changes. Expense versions reject stale edits. Client UUID and exact request payload journals make uncertain retries safe. Reconciliation requires a settled balance and review note, locks new payments, and can be explicitly reopened with history. This phase does not automatically import personal budget records, send payment requests, charge cards or deliver emails.

Validation: shared-ledger.sql.test.cjs uses real PostgreSQL semantics via PGlite for permissions, retries, balances, refunds, revocation and reconciliation; shared-ledger.ui.test.cjs exercises mobile forms, currency grouping, retry keys, read-only views and dialog closure.
