# Shared vendor quotations and bookings

Install supabase/vendor-commercial.sql after shared-vendors.sql. Personal quotations, bookings and finances are not imported automatically.

Team directory > View professional > Quotes & bookings provides quotations, comparisons in original currencies, recorded confirmations, service details and planned payment milestones. Prices, contract/cancellation terms, quote snapshots and payment schedules require both vendor access and financial permission. Editing additionally requires planning-write permission. Other allowed vendor readers see only the explicitly reviewed booking title, service instructions, service date, status and any celebration ID they can already access.

The server calculates totals from subtotal, tax, service charge and delivery. Bookings require an explicit attestation of agreed details, a current received quotation and its exact revision. An agreed quotation is frozen once booked. One booking per quote; expired, Draft and Declined quotes cannot be booked. Payment milestones are optional, up to twelve, with distinct IDs and positive two-decimal amounts. When present they must sum exactly to the agreed quote total, in its original currency.

Project locks, account-owned request keys, exact retry-payload comparison, optimistic revisions and stored snapshots prevent duplicate/conflicting saves. Versions and activity history persist. Cancelled bookings remain preserved and cannot be reopened in place. No money is moved, no expense is automatically created and no milestone is inferred to be paid. Shared ledger and actual payment/reconciliation workflows follow separately.

Checks cover financial permission removal, operational redaction, exact totals, stale/retried saves, frozen quotes, booking attestation, expired quotes, milestone totals/duplicate IDs, cancellation history and mobile comparison/booking forms. Tests use mock accounts and do not contact vendors or send funds.
