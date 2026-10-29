# Shared property comparisons and viewings

## Activate
Run `supabase/home-properties.sql` in Supabase SQL Editor after the shared home setup. Ready-to-run copy: `C:/Users/ayeni/Downloads/cobridey-home-properties.sql`.
Open Home Setup → Plan our home together → open home plan → Properties & viewings.

## Privacy
Property and viewing records inherit the exact home audience. Wedding ownership/planner status does not expose another creator's private plan. Only home editors can change records, while viewers can read and compare them. Archived plans are read-only to their creator and unavailable to former collaborators. Adding or editing a property requires explicit confirmation that its location and quoted costs will be visible to home participants. Viewing contacts and notes share that same audience. No private account records are automatically imported.

## Behavior
- Property shortlist: name, location, listing/photo URLs, tenure, bedrooms, original-currency quote, payment period, deposit, other fees, notes and status. Quote fields may be left blank. Purchase asking prices require One-time cadence. One Chosen property per home; choosing another requires reviewing the existing choice first. This is a planning choice, not an application, lease, mortgage approval or payment.
- Compare up to six properties. Quotes remain separated by currency and period. No conversion, affordability recommendation, receipt, payment or financial ledger entry is inferred.
- Viewings: local start/end, IANA time zone, UTC instants, contact, seven reviewed/not-reviewed checklist areas, notes and optional 1–5 overall impression. Invalid dates and nonexistent daylight-saving times are rejected. Times must run forward within 24 hours. Completion cannot be recorded before the start. Scheduled/confirmed viewings cannot overlap within one home plan. Old completed/cancelled viewings remain records. Outstanding viewings must be cancelled before passing/archiving a property.
- Follow-up: explicit task title, date and accepted home participant assignment. One task per viewing, created atomically through the existing home-item RPC. No silent copying of contacts/notes, duplicate task lists or extra purchases. Link opens and highlights the canonical home task. Later viewing cancellations do not silently delete an existing task.
- Direct table access is revoked and RLS enabled. All mutations recheck home permissions, archived state, home/property/viewing revisions and exact per-user request IDs. Immutable home history records every property/viewing version. Source membership/sharing changes take effect immediately.

## Tests
`home-properties.sql.test.cjs`: migration rerun, creator-only privacy, viewer restrictions, exact retries, stale revisions, quote/URL/date validation, overlap prevention, chosen-property guard, source permissions, task atomicity, assignment, revocation and history. Uses PGlite via CB_PGLITE_PATH.
`home-properties.ui.test.cjs`: 390px mobile flow, explicit sharing confirmation, interrupted-request retry, multi-currency/period comparison, viewing checklist, assigned follow-up, read-only controls and desktop/mobile screenshots. Uses Playwright via CB_PLAYWRIGHT_PATH.
Auth and shared-home regression tests protect native navigation, existing household records and source links. Real account/device testing remains deferred at the user's request.

## Boundaries
Listing and photo links are recorded; this does not connect a property provider or guarantee listing availability. There are no external appointments, emails, calendar sync, applications, document uploads or payments in this phase. Home/property cost links to the existing ledger can be added separately.
