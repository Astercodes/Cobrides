# Part VIII — Universal registry, gifts and contributions

Module 25 adds a browser-local registry for retail/household gifts from multiple providers, cash gifts, honeymoon/home funds, experiences and charity entries. Each entry stores its currency, region/delivery guidance, external HTTPS link, target/quantity and explicit public visibility.

Reservations and group contributions share a target with over-reservation protection. Gifts move through recorded external purchase, shipment, receipt, cancellation or return states. Giver identities, anonymous designation, tracking references, thank-you drafts and externally sent acknowledgment status are maintained in a private ledger. Cash contributions never transfer funds or silently change wedding finance balances.

Real shopping items can be linked once, with matching quantities. Fully received gift quantities appear as Gift received in commerce inventory. Partial receipts remain outstanding; returns remove that received quantity. Active shopping orders/owned stock prevent duplicate reservations; outstanding registry gifts prevent duplicate shopping orders. Registry entries and received gift history remain connected even when archived.

Public entries embed in the wedding mini website and its self-contained HTML export. The export uses an allowlist and excludes giver identities, acknowledgment drafts and delivery references. Public totals are explicitly snapshots. Private ledger CSV exports contain giver information and should only be shared deliberately.

Current boundary: reservations and delivery updates are manual and local to one browser. No public guest reservation endpoint, cross-device locking, retailer API synchronization, live shipment tracking, payment collection or automated thank-you delivery exists. A production universal registry requires authenticated accounts, a database with transactional reservation enforcement, hosted public routes and provider integrations. Region fields document availability; they do not verify retailer shipping coverage or calculate customs.

Validation: all model suites and static build; new registry tests cover capacities, group funding, receipts/returns, linked inventory, duplicates, scope isolation and public export privacy. Browser tests cover public honeymoon fund creation, anonymous contribution receipt, acknowledgment drafts, linked retail gift receipt, commerce inventory, website embedding and mobile layout.


Sample registries seed once per sample wedding: twelve entries across retail gifts, cash, honeymoon, home furnishing, experience and charity categories; seventeen gift/reservation records show group gifts, anonymous/private wishes, received gifts, shipping, returns, cancellations and thank-you drafts. Six household shopping records share gift inventory. Public website snapshots exclude private entries and giver details. Financial contribution records remain separate to avoid double-counting cash; no money or messages are sent.
