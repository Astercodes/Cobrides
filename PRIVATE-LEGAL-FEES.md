# Private documentation fees

Open Marriage Documentation, open a step, then choose Fees & payments. The owner reviews a safe financial title, supplier, currency and agreed amount, or links a whole existing ledger expense. Explicit confirmation is required. This creates an obligation, never a payment or an official application status.

Personal notes, document titles, witnesses, references and source URLs remain private. Native project financial permissions control the shared ledger. Private source ownership controls the connector. Scope and project mapping are verified server-side; changed estimates require review without rewriting agreements. Exact retries, source hashes and expense/link revisions prevent duplicate or stale writes. Existing payments, refunds and settlement adjustments are retained. Home, travel and shopping allocations cannot be reused as an unrelated documentation fee.

Earlier personal estimates are preserved. Review them and select an existing shared expense where appropriate; no automatic historical conversion occurs.

Activation: run supabase/private-legal-fees.sql after existing financial, home and travel migrations. The migration is rerunnable and does not send emails. Tests use PGlite with actual financial migrations and a mobile browser with mocked authentication/RPCs; real account multi-device validation remains deferred.

Validation: private-legal-fees.sql.test.cjs, private-legal-fees.ui.test.cjs, auth-session.test.cjs and legal-samples.test.cjs. Production activation requires the SQL migration.
