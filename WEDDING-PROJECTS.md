# Wedding project backend

Apply `supabase/wedding-projects.sql` after collaboration.sql and accounts.sql. The migration is transactional and rerunnable. Existing account workspaces remain intact.

Wedding Projects offers Connect wedding team for existing personal projects; new projects connect after the personal save succeeds. The dialog manages shared metadata, invitations, membership, celebration access, archive/restore, and activity. Invitations can be shared through email, WhatsApp, messages, or a copied link. Accepting requires the invited verified email account. Planner ownership transfers require an explicit bride invitation.

Server permissions and row-level security control every shared read and mutation. Financial visibility is separately granted; vendor/guest celebrations require explicit assignments. Revision checks reject stale writes. Removing membership immediately blocks subsequent server access. Shared details refresh while the workspace is visible.

Only whitelisted project and celebration metadata is shared. Personal tasks, conversations, guest lists, journals, purchase records, and detailed financial ledgers are not automatically published. Shared responsibility/message records in collaborate.html retain their existing collaboration model. Connect those individual modules deliberately in later work.

Validation: wedding-projects.test.cjs covers client metadata selection, namespaces, imported permissions, and revoked access. wedding-projects.sql.test.cjs runs real migrations twice against PGlite when CB_PGLITE_PATH points to its runtime, checking row isolation, invitations, finances, event assignments, conflicts, archive/restore, and revocation. Production acceptance still requires two real accounts to test invite delivery/acceptance and cross-device updates.


## Shared planning

Apply `supabase/shared-planning.sql` after wedding-projects.sql. It upgrades the existing shared task table, backfills legacy task references, removes direct browser inserts, and preserves the older completion endpoint with current authorization checks.

Planning & Tasks opens Shared tasks & milestones; the Wedding team dialog also has this tab. Owners, brides, partners and planners manage assignments. Other members see and complete only their own tasks. Assignment requires an accepted member or project owner email. Personal checklist sharing is explicit, with title/date/type reviewed first; attachments, subtasks, private notes and discussions are excluded. Shared instructions must be entered separately.

Task saves and completion use revisions. Stale writes fail with a refresh message. Archived projects reject edits, and removed members lose reads and completion access. Use Refresh updates or reopen the tab to fetch current team records. Shared date links and rescheduling are implemented below. Shared planning now generates the in-app notifications described below; email and push reminders are not sent.

Mobile browser validation used a local API fixture and the actual application UI: created a milestone and completed it at 390px without page overflow or JavaScript errors. SQL integration tests verify real database permission rules separately. A real two-account invitation acceptance test remains a production acceptance step.


## Standalone Wedding Team

`journey.html#team` is a first-class navigation route under Wedding Project Planning. It replaces the project team modal with a responsive page, project selector, live summary counts and section navigation. Opening team actions routes here; editing a shared project selects its Project details tab. Shared task entry points select Tasks & milestones. People and invitation controls retain the same server authorization. No database migration is needed for this presentation change.


## Main planning board

Apply `supabase/task-board.sql` after shared-planning.sql and the existing storage/record migrations. The transaction preserves the installed file cleanup checker and adds shared attachment protection. It is rerunnable.

The main task board projects permitted shared rows alongside personal tasks without storing those shared rows in account snapshots. A published personal task retains its private source record and no longer appears twice. Sharing requires explicit review; private instructions, conversations, dependencies and files are not automatically published. New team tasks, assignment editing, subtasks, prerequisites, designated approval, discussions and private shared-file downloads use permission-checked server functions.

Shared prerequisites reject cycles and incomplete dependencies. Completion also requires finished subtasks and any designated approval. Only the named approver can approve. Edits invalidate approval; completed tasks must be reopened before edits, and completed downstream tasks block reopening prerequisites. CAS revisions protect concurrent changes. Comments and attachment additions are independent append operations. File ownership is verified before sharing, attachment RLS follows task access, downloads use 60-second signed URLs, and linked files are excluded from unused-file cleanup.

Visible planning boards poll every 30 seconds when no dialog/search editing is active. Unchanged results do not redraw the board; Refresh team updates fetches immediately. Server permission checks remain authoritative for every mutation. Reassignment/removal blocks subsequent reads and new download links. Already downloaded files cannot be recalled.

Validation includes SQL integration tests with actual migrations and storage RLS, account-scoped projection tests, and an actual mobile browser flow against a local API fixture for combined board display, creation, completion, subtasks and discussion. Real production account-to-account acceptance testing remains separate.


## Shared Celebrations workspace

Apply `supabase/celebration-workspace.sql` after wedding-projects.sql. The rerunnable transaction extends the existing event mutation with shared status, program and menu overview, validates date/time/status fields, preserves revision checks and uses the existing event access policies. No personal guest list, expense, purchase or private note fields are accepted.

The main Celebrations page projects permitted shared events alongside personal drafts. Explicit source IDs preserve existing private record links without copying server updates into private drafts. Share with team opens a review form; new celebrations in connected projects use the shared editor. Shared edits from Wedding Team are fetched back into the main workspace; visible pages poll every 30 seconds and have a manual refresh. Project counts and timeline entries use the same event projection. Completed events are recognized by the timeline.

Private records are managed separately. A user can retain their own event budget, guest/vendor/purchase/expense links in their account without publishing them. Missing shared financial data is not presented as a zero wedding budget. Source drafts remain stored when shared access is removed. New private record handles contain only their own private values and the shared event reference.

Shared date changes now use the timeline rescheduling preview described below. Local relative schedules continue to use projected event dates. No hard-delete workflow is introduced.

Validation: SQL integration cases cover stale updates, invalid dates/times, metadata whitelisting, restricted event assignment and revocation. Projection tests verify source-ID preservation, account isolation and private fields. Browser testing with actual UI and a local API fixture covers creating/sharing without duplicates, main-page edits, team edits reflected on the main page, private-budget editing and guest-link preservation at 390px without JS errors or horizontal overflow. Production account-to-account acceptance testing remains separate.


Wedding Team now contains only People & invitations and Activity. Its summary covers roles, membership and pending invitations. Shared project editing opens from Wedding Projects in a focused dialog; tasks stay on the main planning board. Celebration-specific permissions open from Manage access within the celebration, preserving existing grant/revoke RPCs. Browser checks cover the two-tab team view, shared-project editor and event access changes without navigating away. No additional SQL is required for this navigation cleanup.


## Shared timeline rescheduling

Apply `supabase/shared-timeline.sql` after the shared planning, task board and celebration migrations. It is rerunnable. Timeline & countdowns offers Reschedule timeline and Manage date links. Project and celebration date editors open the same preview flow.

Celebrations can follow the wedding date; tasks can follow the wedding or one celebration by a signed day offset. Saving a rule does not change dates. A server-generated preview lists the proposed dates, completed records retained, dependency conflicts and approvals that will reset. Unlinked fixed dates move only when selected. Completed tasks and celebrations remain unchanged.

Previews expire after 15 minutes. Application checks current membership, write access and a fingerprint of project, events, tasks and rules, then commits all dates in one transaction. Concurrent edits require a fresh preview. Applied requests can be retried without applying the shift twice. Linked dates cannot bypass this flow through legacy editors. Private account records are excluded. Vendor availability and notification delivery are not inferred.

Visible timelines refresh shared metadata, celebrations and tasks every 30 seconds while no dialog is open. Validation covers real SQL permissions, stale/expired previews, dependency conflicts, idempotency, protected fixed/completed dates and approval resets. A mobile browser fixture verifies preview, apply and rule editing at 390px without overflow or JavaScript errors. Production testing with two signed-in accounts remains a separate acceptance check.


## Shared planning notifications

Apply supabase/planning-notifications.sql after shared-timeline.sql. The rerunnable migration adds account-owned notification and preference tables, database triggers, protected inbox/read/preference functions, and an hourly Supabase Cron job named cb-planning-reminders (minute 15). On platforms without pg_cron the inbox still evaluates reminders on refresh; Supabase production has the job installed and verified active.

Notifications cover assignment, task completion, approval requests/results, task deadline changes and project/celebration date changes. Actors do not receive their own event notices. Assignees, approvers and managers receive only records their current permissions allow. Membership removal, reassignment, restricted-event access changes and archive are checked at read time. Old approval requests disappear when approved or reassigned. Completed tasks and changed deadlines hide obsolete deadline reminders. No private personal records or financial fields are copied.

The server calculates reminder dates using each recipient's saved time zone (UTC by default). Upcoming tasks and milestones have one reminder in the three-day window, one due-today reminder and one overdue reminder per deadline; celebrations have upcoming and day-of reminders. Unique recipient/deduplication keys protect against simultaneous browser refreshes and scheduler retries. Preferences control assignments, approvals, deadlines and schedule categories. Read state and preferences persist per account across devices.

The header bell is available in the bridal workspace, collaboration workspace and participant/business portals. It offers Unread, All updates, Preferences, mark read/all read, current source details and authorized task approval. The inbox shows the latest 100 updates with a full unread count. Visible pages refresh once per minute; no polling overwrites an open preferences or detail view. The inbox links to the existing shared wedding workspace rather than duplicating project editing.

These are in-app notifications only. Email and push delivery are not enabled by this migration and do not consume Resend's allowance. Real cross-account acceptance testing remains separate from the SQL integration and local browser fixture checks.


## Optional daily planning emails

Apply supabase/planning-email.sql after planning-notifications.sql. It installs private delivery settings and jobs, opt-in preferences, digest visibility checks, a pg_net sender and a minute-based Supabase Cron processor. The sender is hello@mail.cobridey.com. Add a sending-only Resend key to Supabase Vault with the exact secret name cobridey_resend_api_key; no Vercel environment variable or service-role key is needed. Credentials remain in Vault and are not returned by any browser RPC.

Each account starts opted out. The inbox preferences can enable one summary per local calendar day after 09:00, only when new unread permitted updates exist since opt-in or the last summary. Emails contain a count and authenticated inbox/preferences links rather than private task or celebration details. Reading updates, revoking access or opting out cancels unsent work. An HTTP request already submitted cannot be recalled.

The processor serializes work, rechecks current account/email/access/preferences, freezes each request payload and retries with the same Resend idempotency key. Attempts stop after five tries or twenty hours, before Resend's twenty-four-hour deduplication window closes. It submits at most one message per minute. Provider rejection is recorded; authentication failures pause sending, and throttling backs off. Accepted means the provider accepted the message, not confirmed inbox delivery. Delivery/bounce webhook processing remains separate.

Default application allowances are 50 new summaries per UTC day and 1,500 per UTC month, counted pessimistically at first submission. These are only planning-email limits: they do not measure Supabase authentication email traffic, and both types still consume the same Resend account allowance. Adjust limits in the private settings table after a provider-plan change.

SQL tests cover opt-in isolation, credential protection, daily/monthly caps, frozen retries, throttling, local-time scheduling, access revocation and opt-out. Local mobile UI testing verifies saving the email preference without layout overflow. Real provider delivery testing requires the Vault key and an explicitly selected recipient.


## Resend delivery events and suppression

Apply supabase/planning-delivery.sql after planning-email.sql. The rerunnable migration adds private delivery event metadata, account/address suppression and provider status. Delivery status is separate from request acceptance. Provider email IDs connect callbacks to planning jobs; unmatched callbacks wait for reconciliation so callbacks arriving before the send response are not lost. A minute-based reconciliation job catches busy rows and delayed provider-ID links.

Configure a Resend webhook at https://www.cobridey.com/api/resend-webhook for email.delivered, email.bounced, email.complained, email.failed, email.delivery_delayed and email.suppressed. Save its signing secret as RESEND_WEBHOOK_SECRET in Vercel production and as cobridey_resend_webhook_secret in Supabase Vault, then redeploy. This dedicated shared secret authorizes only event ingestion; no service-role key is needed. Do not reuse the sending API key.

The API verifies the untouched request body using Svix HMAC-SHA256, timing-safe comparisons and a five-minute timestamp tolerance. It rejects oversized/forged events and forwards only event ID, provider email ID, type and timestamp. The database separately checks the secret, validates events, deduplicates retries and prevents historical delivered events overriding bounces/complaints. Public callers cannot read event/job tables or apply events without the secret.

Hard bounces, complaints and provider suppression turn off planning emails for that address and cancel unsent work. Opting back into the same suppressed address requires support review; a different verified address can opt in separately. Unknown callbacks, including authentication emails without a matching planning job, do not change any account preference. A provider-delivered event means acceptance by the recipient mail server, not proof that a person opened the message.

## Direct invitation emails

`supabase/invitation-email.sql` adds direct sending to Wedding Team. Creating an invitation does not email anyone: the authorized wedding manager chooses **Send email**. The authenticated RPC accepts only an existing invitation ID; recipients, access role, link and branded content are generated server-side. Existing recipient-bound acceptance and ownership-transfer confirmation remain unchanged.

Private durable jobs are unique per invitation. The minute worker rechecks expiry, revocation, archival and sender membership, uses a frozen payload and Resend idempotency key, and retries temporary failures at most five times within 20 hours. Provider acceptance and webhook-confirmed delivery are distinct. Bounce/complaint/suppression events block further invitation delivery to that address. Already submitted mail cannot be recalled.

Launch allowances: 10 email invitations per sender per rolling day, 3 per recipient per rolling day, 25 new invitation submissions per UTC day and 750 per UTC month platform-wide. These reserve part of the current free Resend allowance alongside 50/day and 1500/month planning summaries. Authentication emails and other Resend usage still count toward the provider's shared quota. Exhausted invitation allowance leaves jobs queued; link sharing remains available. Increase these internal allowances together with the provider plan when launch volume requires it.

The existing sending-only Vault key and signed webhook are reused. No service-role key or new credential is needed. SQL integration tests cover role isolation, verified senders, duplicate requests, revoked/expired/archived invitations, signed delivery metadata and retry idempotency. A real two-account acceptance test remains a launch check.
