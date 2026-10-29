# Private spiritual daily progress

## Activate
Run all of `supabase/private-faith.sql` after account workspace record saving is installed. Ready-to-run copy: `C:/Users/ayeni/Downloads/cobridey-private-faith.sql`.
The existing Spiritual Preparation daily prayer, devotional and scripture views connect directly; there is no new access gate or separate workspace to open.

## Scope and privacy
Prayer and scripture have 90 trackable days; the existing uploaded 30-Day Devotional for Brides keeps its 30-day content. This migration adds owner-only daily check-ins, completion undo, conflict protection and one-time migration of valid existing progress. It does not replace the supplied devotional, generate new readings or send content to a model/provider.

All source lookup and progress are scoped to auth.uid(), private bride account records, personal/demo namespace, project, plan, type and start date. Project members, partners, planners and guests have no access through team permissions. RLS is enabled, raw table grants revoked, and only the two authenticated prepare/write RPCs are executable. Journals, prayer requests, notes, spiritual profiles and vow drafts remain in existing owner-only workspace records; they are not copied to progress tables, public activity, team calendars or notifications. The general platform search schema excludes faith records. Logout clears the private progress cache.

## Integrity and behavior
- The account plan must already be saved and match its project, daily-plan type, kind and start date. Retired workspace record versions are ignored and scoped personal records take precedence over legacy unscoped ones.
- Legacy check-ins import once for the original plan start. Only valid, nonfuture dates within its 30/90-day range become progress. The original check-in array is retained privately in the migration snapshot, including any legacy future/invalid entries for recovery.
- Each new start date has separate progress. Existing dates are never silently reinterpreted as completion of another day's readings. Restoring a previous start returns its earlier native progress. Later/stale account copies cannot re-import an undone day.
- The server rejects future days using the supplied valid IANA zone, out-of-range day numbers, missing/mismatched plans and paused/completed/archived plan writes. Future-day checkboxes are disabled in the existing view.
- User/workspace locks, optimistic revisions, exact retry IDs and immutable history make completion/undo safe. An ambiguous failed save retains the same request for Retry saving; a conflict reloads canonical progress instead of overwriting it.
- The tiny inline save/loading/error state reflects actual account saving. Daily notes retain their existing private save behavior. Plan start changes first preserve the old timeline, save the revised account record, then load that start's native progress.

## Validation
- `private-faith.sql.test.cjs`: migration rerun, account isolation, personal/demo separation, namespace precedence, source version matching, legacy import deduplication, future/range validation, completion/undo/retry, conflicting revisions, start-date preservation, paused plans, protected history and anonymous/raw-table denial.
- `private-faith.ui.test.cjs`: actual daily-view rendering, prayer/devotional/scripture controls, prevention of the old browser-only check-in handler, exact retry after an ambiguous save, undo, date-version restoration, future controls, conflict reload and private-field exclusion from RPC requests.
- Auth/session and existing private-care regressions preserve logout and private workspace behavior. Portal preview includes the faith route. Real-account and multi-device testing remain deferred at the user's request.

Further work can cover private counseling attendance and class scheduling; no counseling records, journals or vows were moved into a shared project by this change.
