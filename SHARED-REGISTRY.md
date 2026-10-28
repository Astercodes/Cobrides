# Shared retail registry

Run supabase/shared-registry.sql after the existing wedding project migrations. No personal registry is automatically shared or published. Managers choose a personal retail gift, review its title, source link, image, quantity and currency, then save a shared copy. Personal funds remain in the existing registry.

Authenticated RPCs require current planning-write access on every read/write/retry; raw registry tables and audit history have no client grants. Mutations lock the wedding project, validate exact retries and expected revisions, and reject reservations exceeding the remaining quantity. Delivery transitions distinguish reservations, externally purchased, shipped, received, cancelled and returned gifts. Cancelling/returning frees quantity. This workflow records information and never processes payments or assumes a retailer confirmed purchase. Public guest self-reservation and funds are separate follow-up work.

Tests: shared-registry.sql.test.cjs and stationery-registry.ui.test.cjs. The SQL test validates access denial, raw-table denial, duplicate retry, stale revision, over-reservation and delivery transitions. Browser tests validate reviewed personal imports and an identical retry after interruption. Real-account cross-device testing remains deferred.
