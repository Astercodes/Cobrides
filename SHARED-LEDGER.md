# Shared booking expense ledger

Apply `supabase/shared-ledger.sql` after the vendor-commercial migration. Repeatable and transactional; no existing personal expenses are published or changed. RPCs reload the PostgREST schema cache.

Entry points: Payments & obligations → Shared expense ledger; team vendor booking → Shared expense ledger; collaborator workspace → Shared expense ledger (financial access required).

Connecting a booking is reviewed and unique by booking ID. The agreed amount, currency and payment schedule are captured from the frozen agreement, never marked paid automatically. Subsequent booking edits do not rewrite this snapshot. Cancellation preserves recorded liability and payment history.

Apply `supabase/expense-settlements.sql` after shared-ledger.sql to enable reviewed cancellation or renegotiation adjustments. The original agreed_total stays unchanged; nullable settlement_total holds the latest reviewed commitment. Amounts, comparisons, payment caps and reconciliation use the latest commitment. Adjustments require financial plus planning-write access, an unreconciled expense, the current revision, a reason and explicit vendor-agreement confirmation. Received refunds must be recorded before reducing a commitment below net payments. Zero settlements are supported after refunds. An append-only adjustment history captures previous/new totals, actor and reason. Changes never infer payments or modify the original schedule. The migration is repeatable and retains RPC grants.

Payments and received refunds are append-only records of external transactions, not payment processing. Refunds reference the original expense payment, cannot exceed its unrefunded amount or precede it. Payments cannot exceed the remaining agreed balance. All amounts use native currency with separate currency totals. Financial access is checked for every request; modifications additionally require planning write. Direct table access is revoked and RLS enabled. Team-wide audit messages contain no financial amounts or notes.

Project-row locks serialize writes with bookings and membership changes. Expense versions reject stale edits. Client UUID and exact request payload journals make uncertain retries safe. Reconciliation requires a settled balance and review note, locks new payments, and can be explicitly reopened with history. This phase does not automatically import personal budget records, send payment requests, charge cards or deliver emails.

Validation: shared-ledger.sql.test.cjs uses real PostgreSQL semantics via PGlite for permissions, retries, balances, refunds, revocation and reconciliation; shared-ledger.ui.test.cjs exercises mobile forms, currency grouping, retry keys, read-only views and dialog closure.
