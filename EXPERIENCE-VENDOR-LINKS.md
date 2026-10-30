# Experience professional references

Team experience plan → Professional on a service card references a canonical shared vendor. Authorized planners search active vendors in the same wedding, review a selection and confirm it. Clearing the selection explicitly removes the connection, preserving the source vendor, original supplier text, financial records and contracts.

The connector is planning-only: current native planning write access and access to the celebration are mandatory for reads and writes. Event readers, strangers, expired collaborators and anonymous clients cannot read link details or edit references. Only the vendor's ID, name, category, current revision and archive/change flags are projected; contact details, service notes, quotes, contracts and payments are not copied. Existing shared vendor permissions remain unchanged.

Each write checks the celebration, experience item, link and selected vendor revisions. Exact requests replay safely and conflicts leave form values visible. Names/categories are projected from the current source rather than frozen copies. Archived vendors remain visibly archived on existing links but cannot be newly selected. Unlinking preserves history. Raw tables are locked and sign-out closes connector dialogs. This does not book a vendor or connect financial obligations.

Activation: run supabase/experience-vendor-links.sql after shared-experience.sql and shared-vendors.sql. It is additive and rerunnable.

Tests: native SQL with actual project/access/vendor migrations covers privacy projections, confirm requirement, revisions, exact retries, explicit unlink, changed and archived sources, cross-wedding denial, expired/reader/anonymous denial, source preservation and history. Mobile UI tests cover exact retry, unlink, conflict retention, closure and sign-out reset. Live-account testing remains deferred at the user's request.
