# Shared seating and catering

## Activate and open

Run `supabase/shared-seating.sql` after guest-rsvp.sql and the existing celebration/access migrations. A copy is supplied at `C:\Users\ayeni\Downloads\cobridey-shared-seating.sql`. Installation is replay-safe and preserves guest responses and personal seating records.

Open **Seating & hospitality → Shared seating & catering**, the **Seating & catering** link in Shared guests, or the invited collaborator workspace. Choose a shared celebration, add tables, then assign confirmed guests. Tables have a shape, room/area, capacity, private notes and archive controls. The catering tab shows current meal selections, dietary and accessibility requests. Export refreshes the roster first, then uses the existing format picker (including CSV/PDF/Word/image formats).

## Consistency and permissions

- Current planning managers with access to the celebration can read and change shared seating. Anonymous guests, ordinary guest/team readers and removed/expired members cannot access seating or other households' care requirements. Financial access is neither required nor granted.
- Only named guests with a currently Confirmed native RSVP for the specific event may be assigned. Each person has at most one seat per event. Cross-event and cross-wedding placements are rejected.
- Project locks serialize seating, table edits and RSVP updates. Assignments require the current event revision. Table edits require the current table revision. Exact retries return the original result; changed retries and stale edits cannot overwrite newer work.
- Full tables reject new assignments. Capacity reductions below current occupancy and archiving occupied tables are rejected. A manager must move or unseat guests first. Names are unique among active tables in an event.
- An AFTER UPDATE trigger on shared RSVP households removes seats when a guest declines or loses event eligibility, records the release, and updates event revisions in the same transaction. Current guest meal/care data is read directly from the RSVP records. Revoking an invitation does not cancel an already-recorded attendance confirmation.
- Tables, assignments, revisions and history have RLS with no direct client grants. Seating is not included in public household invitation responses.
- Personal seating plans remain personal. This workspace is driven by reviewed shared households and their native RSVPs. An open view refreshes every twenty seconds; export fetches current data and rechecks access before offering a file.

## Limits and validation

An event supports up to 300 tables, with one to 100 seats per table. Updates are recorded in private history. Catering CSV cells are quoted and formula-prefixed values are neutralised.

With `CB_PGLITE_PATH` and `CB_PLAYWRIGHT_PATH` configured, run:
`node --test shared-seating.sql.test.cjs shared-seating.ui.test.cjs guest-rsvp.sql.test.cjs guest-rsvp.api.test.cjs guest-rsvp.ui.test.cjs`

Checks cover permissions, capacity, table/seat retries, stale edits, event isolation, automatic seat release after public RSVP changes, eligibility removal, migration replay, mobile flows and catering exports. Real-account cross-device testing remains deferred at the user's request.
