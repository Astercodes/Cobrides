# Wedding project backend

Apply `supabase/wedding-projects.sql` after collaboration.sql and accounts.sql. The migration is transactional and rerunnable. Existing account workspaces remain intact.

Wedding Projects offers Connect wedding team for existing personal projects; new projects connect after the personal save succeeds. The dialog manages shared metadata, invitations, membership, celebration access, archive/restore, and activity. Invitations can be shared through email, WhatsApp, messages, or a copied link. Accepting requires the invited verified email account. Planner ownership transfers require an explicit bride invitation.

Server permissions and row-level security control every shared read and mutation. Financial visibility is separately granted; vendor/guest celebrations require explicit assignments. Revision checks reject stale writes. Removing membership immediately blocks subsequent server access. Shared details refresh while the workspace is visible.

Only whitelisted project and celebration metadata is shared. Personal tasks, conversations, guest lists, journals, purchase records, and detailed financial ledgers are not automatically published. Shared responsibility/message records in collaborate.html retain their existing collaboration model. Connect those individual modules deliberately in later work.

Validation: wedding-projects.test.cjs covers client metadata selection, namespaces, imported permissions, and revoked access. wedding-projects.sql.test.cjs runs real migrations twice against PGlite when CB_PGLITE_PATH points to its runtime, checking row isolation, invitations, finances, event assignments, conflicts, archive/restore, and revocation. Production acceptance still requires two real accounts to test invite delivery/acceptance and cross-device updates.


## Shared planning

Apply `supabase/shared-planning.sql` after wedding-projects.sql. It upgrades the existing shared task table, backfills legacy task references, removes direct browser inserts, and preserves the older completion endpoint with current authorization checks.

Planning & Tasks opens Shared tasks & milestones; the Wedding team dialog also has this tab. Owners, brides, partners and planners manage assignments. Other members see and complete only their own tasks. Assignment requires an accepted member or project owner email. Personal checklist sharing is explicit, with title/date/type reviewed first; attachments, subtasks, private notes and discussions are excluded. Shared instructions must be entered separately.

Task saves and completion use revisions. Stale writes fail with a refresh message. Archived projects reject edits, and removed members lose reads and completion access. Use Refresh updates or reopen the tab to fetch current team records. Shared assignments do not yet reschedule automatically or generate email/push reminders.

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

Date edits here do not bulk-reschedule shared task deadlines. Shared timeline change previews and rescheduling remain a later step. Local relative schedules continue to use projected event dates. No hard-delete workflow is introduced.

Validation: SQL integration cases cover stale updates, invalid dates/times, metadata whitelisting, restricted event assignment and revocation. Projection tests verify source-ID preservation, account isolation and private fields. Browser testing with actual UI and a local API fixture covers creating/sharing without duplicates, main-page edits, team edits reflected on the main page, private-budget editing and guest-link preservation at 390px without JS errors or horizontal overflow. Production account-to-account acceptance testing remains separate.


Wedding Team now contains only People & invitations and Activity. Its summary covers roles, membership and pending invitations. Shared project editing opens from Wedding Projects in a focused dialog; tasks stay on the main planning board. Celebration-specific permissions open from Manage access within the celebration, preserving existing grant/revoke RPCs. Browser checks cover the two-tab team view, shared-project editor and event access changes without navigating away. No additional SQL is required for this navigation cleanup.
