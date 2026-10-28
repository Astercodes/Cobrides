# Shared retail registry

Run supabase/shared-registry.sql after the existing wedding project migrations. No personal registry is automatically shared or published. Managers choose a personal retail gift, review its title, source link, image, quantity and currency, then save a shared copy. Personal funds remain in the existing registry.

Authenticated RPCs require current planning-write access on every read/write/retry; raw registry tables and audit history have no client grants. Mutations lock the wedding project, validate exact retries and expected revisions, and reject reservations exceeding the remaining quantity. Delivery transitions distinguish reservations, externally purchased, shipped, received, cancelled and returned gifts. Cancelling/returning frees quantity. This workflow records information and never processes payments or assumes a retailer confirmed purchase. Guest reservations are available through private household invitations after guest-registry.sql; funds remain separate.

Tests: shared-registry.sql.test.cjs and stationery-registry.ui.test.cjs. The SQL test validates access denial, raw-table denial, duplicate retry, stale revision, over-reservation and delivery transitions. Browser tests validate reviewed personal imports and an identical retry after interruption. Real-account cross-device testing remains deferred.

## Invitation-bound guest reservations

Run supabase/guest-registry.sql after shared-registry.sql and guest-rsvp.sql. Owner-only sharing makes an entry available to current non-revoked invitation holders. Editing an item withdraws that approval; ownership transfers also invalidate previous approval. Shared gift records are never automatically made public on wedding websites.

Guests open the existing private RSVP link to reserve retail gifts, cancel reservations or report an external purchase. A project lock prevents oversubscription across guest and manager writes. Request IDs protect interrupted retries. Only the current household’s own reservations are returned, with immutable title/link snapshots rather than later private edits. Purchased gifts require team assistance for further changes. No payment is inferred or collected. Revoked/replaced invitation tokens and archived projects cannot read or mutate reservations. Each household may make 30 successful changes in 24 hours.

The existing /api/guest-rsvp route uses anonymous credentials and strictly selected RPC arguments, keeping invitation tokens in POST bodies. No additional Vercel API function is added. Tests: guest-registry.sql.test.cjs and guest-registry.ui.test.cjs, plus existing RSVP and shared-registry tests. Live multi-device account testing remains deferred.

## Gift follow-through and household inventory

Run supabase/registry-followthrough.sql after guest-registry.sql. Registry and Home Setup open the same permission-controlled Gifts & gratitude workspace. Authorised wedding managers save private thank-you drafts, explicit externally-sent status, delivery references and room assignments. This form never sends messages or infers payment. Follow-up records and their history are excluded from anonymous guest responses.

A gift must currently be Received before it can be selected for household inventory. The reservation is the unique inventory source, so retrying or saving from another view cannot create a second inventory record. The original product title, image, retailer link and quantity are snapshotted on first inclusion. Returned gifts automatically stop counting as held inventory; saved thank-you and receipt history remain intact. These inventory records are shared across the wedding team and are deliberately separate from purchased shopping items and expense records, so no new purchase or expense is fabricated. Existing private Home Setup records are preserved.

Expected gift and follow-up revisions protect against changing receipt state or another manager's edits. Exact request IDs protect retries, and permissions are rechecked before a previously stored response can be returned. Raw tables are private. Tests: registry-followthrough.sql.test.cjs and registry-followthrough.ui.test.cjs. Live multi-device testing remains deferred.
