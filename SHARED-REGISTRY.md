# Shared retail registry

Run supabase/shared-registry.sql after the existing wedding project migrations. No personal registry is automatically shared or published. Managers choose a personal retail gift, review its title, source link, image, quantity and currency, then save a shared copy. Personal funds remain in the existing registry.

Authenticated RPCs require current planning-write access on every read/write/retry; raw registry tables and audit history have no client grants. Mutations lock the wedding project, validate exact retries and expected revisions, and reject reservations exceeding the remaining quantity. Delivery transitions distinguish reservations, externally purchased, shipped, received, cancelled and returned gifts. Cancelling/returning frees quantity. This workflow records information and never processes payments or assumes a retailer confirmed purchase. Guest reservations are available through private household invitations after guest-registry.sql; funds remain separate.

Tests: shared-registry.sql.test.cjs and stationery-registry.ui.test.cjs. The SQL test validates access denial, raw-table denial, duplicate retry, stale revision, over-reservation and delivery transitions. Browser tests validate reviewed personal imports and an identical retry after interruption. Real-account cross-device testing remains deferred.

## Invitation-bound guest reservations

Run supabase/guest-registry.sql after shared-registry.sql and guest-rsvp.sql. Owner-only sharing makes an entry available to current non-revoked invitation holders. Editing an item withdraws that approval; ownership transfers also invalidate previous approval. Shared gift records are never automatically made public on wedding websites.

Guests open the existing private RSVP link to reserve retail gifts, cancel reservations or report an external purchase. A project lock prevents oversubscription across guest and manager writes. Request IDs protect interrupted retries. Only the current household’s own reservations are returned, with immutable title/link snapshots rather than later private edits. Purchased gifts require team assistance for further changes. No payment is inferred or collected. Revoked/replaced invitation tokens and archived projects cannot read or mutate reservations. Each household may make 30 successful changes in 24 hours.

The existing /api/guest-rsvp route uses anonymous credentials and strictly selected RPC arguments, keeping invitation tokens in POST bodies. No additional Vercel API function is added. Tests: guest-registry.sql.test.cjs and guest-registry.ui.test.cjs, plus existing RSVP and shared-registry tests. Live multi-device account testing remains deferred.
