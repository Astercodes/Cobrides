# Shared household plans

## Activation
Run all of `supabase/shared-home.sql` in Supabase SQL Editor after shared shopping, registry follow-through and wedding permissions. The companion copy is `C:/Users/ayeni/Downloads/cobridey-shared-home.sql`. Rerunning is safe; no private account home records are modified or automatically shared.

## Access and behavior
Open Marriage Home & Household Setup → Plan our home together. Creates a separate native, private-by-default plan. Accepted wedding members can be invited as viewers or editors. General planner/project-owner status does not expose another creator's home plan. The creator alone changes sharing and archival. Revoked wedding members immediately lose access.

Home details, move-in date, room checklist, utilities, moving/delivery tasks, safety and responsibilities save through authenticated RPCs. Accepted home participants can be assigned items. Room buttons show actual readiness and filter records. Custom room labels are normalized to existing case-insensitive names. Cancelled records remain editable in a collapsed archive. Tables have RLS, no direct client grants, revision checks, immutable write history and exact request replay protection.

## Connected inventory
An editor explicitly reviews and confirms a safe snapshot from shopping they can access, or received registry inventory if they have project planning permission. Product title, image, URL and quantity are shared, never finance, source notes, giver identities or thank-you messages. Links do not grant access to source records or create purchases/payments/gifts. Each source item can be linked once across household plans.

Readiness follows the canonical source live: shopping must be Delivered; gifts must be Received and enabled for inventory. Returns/cancellations/unchecking registry inventory remove readiness. For installation items, source receipt plus completed setup are required. Manual goods can be marked Already owned; tasks Complete. A snapshot preserves the reviewed product identity if the source is subsequently edited. Current source status remains authoritative.

The first phase does not migrate private property comparisons, housing documents or private home plans. It does not create a duplicate financial ledger or book movers/utilities. Home cost-to-ledger links and dedicated property/viewing workflows remain later phases.

## Validation
- `node --test shared-home.sql.test.cjs` with CB_PGLITE_PATH: migration rerun, explicit privacy, wedding-owner/planner isolation, reader write denial, cross-wedding source rejection, live delivery/gift corrections, source revision checks, duplicate guard, exact retries, task assignment, date validation and room normalization.
- `node --test shared-home.ui.test.cjs` with CB_PLAYWRIGHT_PATH: mobile create/share/retry/link/filter flow, product review, view-only controls, no horizontal overflow, desktop/mobile screenshots.
- Portal preview covers the home entry alongside existing portal routes. Build and auth tests verify static assets and protected navigation.
- Real account/device testing remains deferred at the user's request. Local tests are not a claim of production account testing.
