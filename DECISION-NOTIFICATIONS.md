# Decision notifications and reminders

Run supabase/decision-notifications.sql after shared-decisions.sql and the existing planning notification/email migrations. This extends the existing notification inbox, hourly reminder job and opted-in daily email summary. It does not add a new sending service or send a test email.

Notices cover approval requests, responses, consensus, comments and deadlines. They contain only the proposal title, not quotation amounts or comment bodies. Recipients must still have access to the proposal. Requests and reminders disappear after the recipient approves; old revisions and obsolete deadline states are hidden. Membership removal, expiry, archived weddings and muted categories suppress both the inbox and daily digest. Requested approvers receive each upcoming, due-today and overdue state once per proposal revision/deadline. Dates follow the recipient's configured time zone.

Idempotent proposal and comment retries do not duplicate notifications. Email remains opt-in, verified-address-only, once daily under existing allowances, scheduling and bounce protections. Decision notices are opened through a permission-checked RPC and link to the exact proposal, including proposals older than the first list page. The collaborator decision page includes its own notification bell.

The migration preserves original task/event behavior through private wrappers, replaces dependent RLS explicitly, recompiles dependent functions after renaming, and is repeatable. Reapply this migration last if restoring earlier notification or collaboration-access migrations.

Tests cover recipient isolation, duplicates, preferences, read state, stale revisions, responses/comments, time zones, consent and revoked access. Browser tests verify that View details checks access, marks only the selected notice read and opens the exact proposal. Existing email worker tests use an isolated mock provider, not real emails.
