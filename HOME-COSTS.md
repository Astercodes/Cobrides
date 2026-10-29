# Household costs and the canonical ledger

## Activation
Run `supabase/home-costs.sql` after shared-home.sql, travel-costs.sql and the existing financial migrations. Companion file: `C:/Users/ayeni/Downloads/cobridey-home-costs.sql`. The migration is rerunnable and does not rewrite agreements, payment journals, property quotes or household records.

Open a shared home plan → Household costs. It reads canonical commitments, revised settlement totals, signed net payments/refunds and remaining balances, grouped by original currency.

## Permissions
Both explicit home access and project financial permission are required to read costs. Home access alone returns no expense fields, choices or totals. Only the home creator with planning and financial editing permissions can create/review links. This avoids an editor unexpectedly disclosing another person's private home details. The creator explicitly reviews the expense title, supplier, category, currency and agreed total. Room labels, home notes, property details, source URLs, donor identity and private notes are not copied into the financial ledger or project activity.

## Integrity
- Reuses `cb_create_retail_expense` and the existing ledger, settlement, payment, refund, schedule and receipt workflows. No separate payment journal and no inferred booking, receipt, transfer or paid status.
- One expense per home item, and one household allocation per expense. Existing obligations can be selected without creating duplicates. Correcting a link preserves the original expense and journal entries.
- Linked shopping must use its existing canonical shopping expense. If none exists, review the purchase in Shopping first. It cannot create a second home obligation. Received registry gifts are excluded from obligations entirely. Record a genuine shipping/installation obligation separately if needed.
- Existing expenses cannot be allocated to both travel and home; symmetric guards reject either linking direction. Travel's existing permissions, fields and labels are preserved.
- New manual household costs require explicit confirmation of an agreed commitment. Item progress alone does not establish that anything was ordered, delivered or paid. Property quotes are not automatically committed.
- Changed home item revisions and changed shopping cost links flag a review. Returned/cancelled shopping shows a warning but preserves obligations and payments for explicit reconciliation. Cancelling a household item never silently cancels a supplier obligation or invents a refund.
- Financial projections retain existing booking/travel/retailer behavior and identify native home commitments accurately. Generic activity text contains no private home context.
- RLS, revoked raw table access, current permission checks, project locking, source/home/expense/link revisions and exact request replay protect mutations. Connection history is immutable.

## Validation
`home-costs.sql.test.cjs` loads the actual canonical finance, settlement, payment/refund, shopping, travel, registry and household migrations. Checks migration reruns, privacy, stale changes, exact retries, currency separation, canonical balances, gift exclusion, shopping reuse, return warnings, cross-wedding rejection, symmetric travel/home allocation guards, correction history and cancelled-item reconciliation.
`home-costs.ui.test.cjs` checks mobile review/retry, unchanged parent home revision, private-field exclusion, nonfinancial redaction, shopping expense restrictions, gift exclusion and close behavior.
Shared home, auth and property regressions ensure existing native workflows remain intact. Real-account and multi-device testing remain deferred at the user's request.
