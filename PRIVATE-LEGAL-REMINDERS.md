# Private documentation reminders

## Activate
Run `supabase/private-legal-reminders.sql` after private-legal-progress.sql and private-appointment-reminders.sql. Companion: `C:/Users/ayeni/Downloads/cobridey-private-legal-reminders.sql`.
Open Marriage Documentation → open a step → Reminders. Existing record forms also have Reminders. Deadline and Document expiry settings are independent, off by default, and owned by the signed-in account.

## Behavior
Choose 1, 3, 7, 14 or 30 days before the saved date and an IANA reminder zone. Reminders become due from 09:00 on the lead date. Date changes retarget the reminder without silently rewriting the record. Native checklist completion/skipping suppresses deadlines; expiry alerts stay independent of completion but not of explicit not-applicable status. Archived/deleted records or projects invalidate reminders. Past dates can show in-app alerts; new email opt-in requires a current/future date. No repeated daily emails are created for the same date/settings version.

Owner-only settings use source-date confirmation, revisions and exact request IDs. Turning both channels off remains possible after the source changes or disappears. Notifications are project-less and owner-only. User/device/project changes reject late results. Logout closes the reminder view. Email/inbox deep links recheck ownership and current source before showing record details.

## Delivery and privacy
Uses the existing Resend Vault key, sender, email-job table, global daily/monthly allowance, pacing, retries, suppression and signed delivery webhook. There is no second sender, billing allowance, new credential or new provider setup. Private reminder jobs remain excluded from daily shared summaries.

Emails say only that a private planning date needs attention. They contain no record title, document type, due date, application reference, witness name, private note or identity document. Details require sign-in. At dispatch the existing worker locks the owner's account workspace and reminder setting and revalidates the current source, opt-in, verified recipient and delivery suppression. Date edits, completion, deletion and opt-out cancel stale queued jobs. Provider acceptance remains separate from confirmed delivery.

The migration adds a five-minute generator job when pg_cron is installed; the existing mail worker also generates due private documentation notices. The settings view warns if background scheduling is unavailable. Email still respects the existing application's sending allowance and provider limits; this migration does not raise them. No real test emails were sent during implementation.

## Compatibility
Adds private_legal to the existing source-kind constraint without discarding prior categories. Rebinds the inbox RLS policy and notification wrappers. Existing care reminders retain their source behavior and branded appointment template. Mail templates are extended only for the new private legal type. No fees, submissions, document verification or legal eligibility are inferred.

## Validation
- `private-legal-reminders.sql.test.cjs`: real prior reminder/email/progress migrations, reruns, owner isolation/RLS, exact retries, current dates, completion-versus-expiry behavior, source edits, pending-job cancellation, past dates, private digest exclusion, global allowance, signed delivery/bounce suppression, deletion/opt-out and existing care delivery compatibility. HTTP sends are captured by a local mock, not the provider.
- `private-legal-reminders.ui.test.cjs`: 390px settings, exact retry, independent deadline/expiry settings, private-field exclusion, past-date email controls, deep links, close and logout reset.
- Auth, current legal-progress and existing private-appointment reminder regressions protect prior behavior. Real-account/multi-device testing remain deferred at the user's request.
