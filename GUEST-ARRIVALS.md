# Guest arrivals and check-in

Run `supabase/guest-arrivals.sql` after shared-seating.sql. A downloadable copy is at `C:\Users\ayeni\Downloads\cobridey-guest-arrivals.sql`. It adds private arrival records and extends the existing seating workspace without changing seating assignments or public guest links.

## Flow

Open **Seating & hospitality → Shared seating & catering → Arrivals**. Select a celebration, search guest/household names, filter expected or checked-in guests, and confirm an arrival. Authorised planning managers can correct a mistaken arrival with a required reason. Arrival lists export through the existing format picker after fetching the latest records.

Arrival timestamps are stored as absolute instants and displayed in the staff device's local time. This feature records check-in and corrections, not guest departures. It does not change RSVP confirmations, invitations, table assignments or payments.

## Integrity and access

- Current planning managers with celebration access can read and write arrivals. Anonymous invitation holders, ordinary readers, removed/expired collaborators and archived-project users cannot access arrival records.
- A new or repeated check-in requires a currently Confirmed native RSVP for that specific event. Wrong-event and declined/uninvited guests are rejected.
- Project locks and per-guest/event expected revisions serialize conflicting edits. Exact request retries return the original result; changed retries, stale revisions and duplicate check-ins cannot add another arrival.
- Corrections require a non-empty reason. Current status, original timestamp and every update remain in private activity history. A genuine later check-in receives its own timestamp/history entry.
- If an RSVP changes or a named guest is removed after arrival, the existing arrival record is retained with a review flag. The recorded guest/household name remains readable by managers. Staff can review it with the couple or correct a mistaken check-in. Seats continue to follow the existing RSVP-release rules independently.
- Arrival changes do not advance seating revisions, preventing busy check-in activity from needlessly conflicting with seat assignments.
- Direct table grants are denied. The old seating-view helper is private; the protected public-facing management RPC returns arrivals only after the original seating permission checks. Public household invitation responses do not include arrivals or staff notes.
- Search focus is preserved during background refresh. The open workspace refreshes every twenty seconds, or immediately via Refresh.

## Validation

With `CB_PGLITE_PATH` and `CB_PLAYWRIGHT_PATH` configured, run:
`node --test guest-arrivals.sql.test.cjs guest-arrivals.ui.test.cjs shared-seating.sql.test.cjs shared-seating.ui.test.cjs`

Tests cover role/event access, duplicate/retry conflicts, required correction reasons, changed/removed guest review, public privacy, archive/revocation, migration replay, mobile search/check-in/correction and current-data exports. Real-account cross-device testing remains deferred at the user's request.
