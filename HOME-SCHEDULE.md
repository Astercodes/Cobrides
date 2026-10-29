# Home arrival schedule

## Activation and entry
Run all of `supabase/home-schedule.sql` after the shared home and property/viewing migrations. Companion: `C:/Users/ayeni/Downloads/cobridey-home-schedule.sql`.
Open a shared home plan → Moving & deliveries. Appointments are available to the same explicitly chosen home participants; no new public/team-wide audience is introduced.

## Behavior
Record moving crews, delivery windows, installations, utility visits and maintenance appointments against an existing household item or task. Each appointment has a title, original local start/end and IANA zone, UTC instants, status, optional coordinator, contact, address and shared instructions. Upcoming/completed/cancelled tabs, type/date filters and links back to the canonical household item keep records manageable. Original location times are displayed, avoiding a device's time zone silently changing arrival expectations. Past open windows are flagged for review.

The coordinator must be an accepted wedding participant who has access to this home. Home editors schedule/edit; home viewers read only. Wedding owner/planner status alone does not expose another creator's private home. Revoked audience/member access applies immediately. Archived plans cannot be changed.

## Scheduling and source integrity
- Active appointments for the same item or the same assigned coordinator cannot overlap within this home plan. Independent items with different coordinators may overlap. Cross-home/private personal calendars are not inspected.
- Clashes with active property viewings in the same home are flagged, without claiming which person is attending. These are review warnings because viewings do not have an assigned coordinator.
- Window end follows start within 24 hours. Invalid dates, unknown time zones and nonexistent daylight-saving times are rejected. Completed status requires the start to have passed.
- Appointment editing checks source item, home and appointment revisions. Linking an existing appointment to a different item/home is rejected. Exact per-user request IDs make interrupted retries safe. Immutable home history records creation, reschedules and cancellation; raw table access is revoked with RLS enabled.
- Completing a visit changes only the appointment. It does not mark the purchase delivered, confirm receipt of a gift, complete room setup, record payment or cancel an obligation. The item link opens the canonical household record for separate review. Linked item cancellation is shown as a warning rather than silently cancelling a supplier appointment. Contact/address/instructions stay inside the home audience; no generic project activity copies them.

## Boundaries
These records coordinate arrangements made with suppliers; there are no external bookings, sent messages, calendar-provider sync, automatic shipping updates or appointment reminder emails in this phase. No private personal records are imported or shared automatically.

## Validation
- `home-schedule.sql.test.cjs`: real home/property RPCs, migration rerun, explicit privacy, viewer restrictions, accepted coordinator checks, optimistic revisions, exact retries, item/coordinator conflicts, parallel visits, source isolation, local/UTC times, viewing warnings, completion boundaries, source readiness preservation, revocation, archival and history.
- `home-schedule.ui.test.cjs`: 390px flow, create/retry/filter/edit/completed tabs, coordinator assignment, source readiness stays separate, read-only controls, protected item links and desktop/mobile screenshot review.
- Auth and existing home/property/finance regression tests protect native routes and canonical records. Real account/multi-device testing remains deferred at the user's request.
