# Connected finance validation

Run `npm run test:shared-finance` with `CB_PGLITE_PATH` pointing to the installed PGlite module and `CB_PLAYWRIGHT_PATH` pointing to the installed Playwright package. The runner fails if either dependency is missing, rather than reporting a suite full of skipped checks. Tests run with concurrency two to limit browser/database memory use.

The suite includes shared vendor quotations/bookings, the expense ledger, settlements, reviewed schedules, notifications, financial reports and exports, receipt storage policies, contributions, contribution notices, support assignments, shared budgets, mobile workflows and the authentication gate. It creates isolated PostgreSQL fixtures and mocked local browser pages. It never sends real emails, charges payments or changes production wedding records.

`shared-finance.integration.test.cjs` installs the complete financial migration chain, creates a realistic booking/expense/pledge/receipt/support/budget setup, and reapplies the migration chain with live fixture data. It checks cross-feature integrity guards, contributor isolation, financial delegation/revocation, private storage access, forecast/payment separation and obsolete reminder visibility after settlement and schedule changes.

The regression found that the earlier expense-reminder migration narrowed the notification source constraint on reapplication. Its allowed sources now retain contribution notifications. Production already has that broader constraint from the contribution-notification migration; no new SQL activation is needed for this correction.

Latest completed run: 83 checks passed, zero failures and zero skips, including the complete migration reapplication and connected-workflow fixture. The static production build also passed.

Automated tests do not replace a live two-account, two-device walkthrough. Remaining release validation should use an ordinary bride account and an invited collaborator account to check deployed Supabase policies, storage uploads, actual sign-in/session behavior, mobile rendering, reconnects and notification timing. Provider email deliverability and money movement require separate authorized checks; these tests do not claim either.
