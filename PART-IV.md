# Part IV — Financial management

Implemented as browser-local planning records. No funds are held, moved, or automatically verified. No requests, reminders, or acknowledgements are transmitted.

## Budgeting and forecasts

Each wedding project has a base currency, overall budget, category and celebration allocations, savings goal, own savings, planned monthly savings and contingency percentage. Expense records include an estimate, agreed subtotal, tax, service charge, delivery/fixed charges, vendor, responsible stakeholder, celebration allocations, deadline and supporting documents. Shared celebration costs are divided equally and counted once in project totals.

Tax and service charge each apply to the subtotal; delivery is added afterwards. A currency entry preserves its manually entered rate to the project base currency. Existing records do not change when another entry uses a new rate. Base currency is locked once financial records or nonzero event allocations exist. Rates are not live market quotes.

Estimated, committed and actual spending are distinct. Actual expense cost is active payments less refunds. Forecast uses the largest of expected expense cost, net actual cost and active scheduled obligations, excluding reimbursements. Cancelled expenses retain actual costs. Contingency is added to the forecast. Alternative scenarios scale forecast costs, add extra costs and apply their own reserve without changing the real plan. Overruns and overdue obligations appear in the relevant views.

## Contributions and sponsorships

Cash, in-kind and item sponsorship commitments have a promised amount/value, deadline, linked stakeholder or fallback sponsor name, optional expense, supporting files and separate receipt records. Cash received contributes to funds on hand; assessed in-kind value does not. A sponsor paying a vendor directly can be recorded as that stakeholder's expense payment rather than a cash outflow from the couple's fund. Do not also record the same payment as cash received unless money actually entered the fund.

Sponsor-filtered views show commitments and receipts. Private/anonymous settings mask names in standard contribution views and CSV reports; they are presentation controls, not authenticated access enforcement. A reveal switch is available on this device. User-entered titles and notes are not automatically scrubbed. Full JSON backups contain raw records. Request notes download for manual sharing; acknowledgements are local status records.

## Payments and reconciliation

Expense-linked deposits, installments, balances, cancellation penalties and reimbursements have amounts, currency snapshots, due dates and requested/scheduled/cancelled states. Penalties use a separate Cancellation expense. Reimbursements affect fund cash flow without adding the original cost twice. Record actual movements only on or before today. Refunds reference the original payment and retain its currency, rate and payer; their total cannot exceed that payment. Entries can be voided and restored. Payments with active refunds cannot be voided first. Reconciliation is a manual check against proof, not provider confirmation.

Existing Stripe, Paystack, Flutterwave, PayPal or other HTTPS hosted checkout URLs can be stored and opened externally. The destination host is displayed. Provider labels do not verify merchant identity. This is a link handoff, not an API integration: authenticated backend endpoints, provider SDKs, signed webhooks and server-side authorization are still required for production payments. FURBRIDES never collects card details.

## Migration, files and exports

Legacy Paid expenses become one manually unreconciled payment with an unknown legacy date. Legacy Deposit paid records are flagged for an actual amount instead of inventing a deposit. Legacy financial stakeholder commitments migrate once into canonical contribution records. Receipts/documents use the existing three-files, 200 KB-per-file local attachment limit. CSV reports include summary, costs, allocations, scenarios, contributions, obligations and ledger data, with formula-prefix protection. Files remain in browser storage; exports are manual backups without an import flow.

## Landing previews

The Professionals section has category selection and shortlisting; Finishing Touches has saveable sample wishes with live totals; Numbers has budget/guest sliders with a changing chart and overrun calculation; Anticipation has a date selector, celebration tabs, countdown and reverse milestones. These are labelled samples and do not modify the personal workspace.

## Validation

Pure-model tests cover idempotent legacy migration, currency/charge snapshots, deposits and refunds, over-refund rejection, private labels, cash versus in-kind funds, shared allocations, scenarios, cancellation costs, unsafe checkout URLs and spreadsheet formula protection. Browser checks cover actual forms, persistence and responsive previews.
