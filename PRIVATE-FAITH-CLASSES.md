# Private counseling and class attendance

## Activate
Run all of `supabase/private-faith-classes.sql` after private account workspace record saving is installed. Companion: `C:/Users/ayeni/Downloads/cobridey-private-faith-classes.sql`.
Spiritual Preparation → Counseling & classes uses its existing calendar and Edit schedule form; no new workspace or access gate is added.

## Behavior
Each existing class has one session, or the existing twelve-session repeating schedule. The calendar now marks a date complete only after all its sessions have attendance recorded. Each visible session has an Attended this session check-in and a course attendance count; unchecking records an undo. Future sessions are disabled and the server verifies the session start in the user's valid IANA time zone. Existing times retain their device-time-zone meaning from the schedule form.

An exact snapshot of start date, time and repeat interval identifies each schedule version. Editing those fields creates a fresh attendance timeline and retains the prior one. Restoring a prior schedule restores its native attendance. Changes to titles, provider names or notes do not reset attendance. Stale schedule/day revisions are rejected instead of overwriting another device's update. Interrupted retries reuse the same request ID. Existing valid, past check-ins import once; later account copies cannot resurrect an undone attendance entry. Raw legacy check-ins are retained privately in the first schedule snapshot.

## Privacy
Everything is keyed to auth.uid(), account namespace and project/record. Partners, planners, counselors and other project members receive no access. Native tables use RLS with client/raw table grants revoked. Only authenticated prepare/save RPCs are exposed. Those RPCs return schedule/progress fields without titles, counselor details, locations, private notes or journal content. No messages, provider bookings, shared calendar events or public activity are created. Logout clears the attendance cache. Account notes, prayers and vows retain their existing private saving.

## Integrity and validation
The server reads current owner workspace records, with personal namespace precedence over legacy records. Retired, moved or recategorized records cannot supply a stale class. Paused/completed/archived courses are read-only. Source validation rejects invalid dates, times and repeat intervals without hiding other valid classes; the view offers Edit schedule for invalid sources. Workspace locks, schedule hashes, per-session revisions, exact retries and immutable history preserve accountability.

- `private-faith-classes.sql.test.cjs`: migration rerun, legacy import, undo/retry/conflicts, reschedule/restore, future/range checks, invalid source handling, namespace precedence, personal/demo/account isolation, paused courses and anonymous/raw access denial.
- `private-faith-classes.ui.test.cjs`: real class calendar rendering, actual attendance markings, checked-state refresh, undo, exact retry after an ambiguous save, future disabling, schedule restoration and private field exclusion.
- Auth/session and daily spiritual progress regressions preserve logout and existing prayer/devotional/Bible behavior. Real-account/multi-device testing remains deferred at the user's request.
