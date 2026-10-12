# CoBrides

A responsive bridal ecosystem prototype built around a persistent Aspiring → Expecting → Engaged journey. The public landing page is `index.html`; the personal workspace is `journey.html`, with its dashboard named Central. Saturated magenta, orange, teal and violet come from the supplied palette reference. The landing page includes five supplied editorial photographs, generated campaign imagery, an original F/B ribbon monogram, scroll reveals, subtle floating animations and reduced-motion support. See `assets/GENERATION.md` for visual provenance and the generation prompt.

## Run locally

Requires Node.js 18 or later. No dependencies are required.

```sh
npm run dev
```

Open http://localhost:4173. Run `npm run check` for JavaScript syntax checks and `npm test` for planning-model regression tests.

## Vercel deployment

Import `Astercodes/CoBrides` into Vercel and select the `main` branch. The checked-in `vercel.json` configures the static build and `dist` output automatically. No environment variables or dependencies are required. Existing Vercel Git integrations deploy when `main` is pushed.

## Included features

- Central with live summaries and fluid chapter switching
- Bridal profile, date, location, budget, style and traditions
- Inspiration concept collections
- Multiple wedding projects from blank, classic and Nigerian multi-ceremony templates
- Independent celebration budgets, details and shared resource links
- Confirmed, tentative and projected dates; candidate-date scenarios; live countdowns and downloadable countdown cards
- Reverse preparation schedules, dependency checks, critical dependency chains and recorded vendor-unavailability constraints
- Tasks, milestones, custom phases/workstreams, owners, due dates, priority, approval records, subtasks, recurrence, local discussion and small file attachments
- Decision, issue, approval and change-request register with local activity history
- In-app reminders and configurable confirmation/payment/purchase follow-up rules
- Expense records with remaining-budget calculations
- Stakeholder relationships, responsibilities, access plans, event assignments, commitments and contributions
- Conversation spaces with local messages, announcements, file/audio attachments, pinning, search, polls and manual acknowledgements
- Message-to-task, message-to-decision and message-to-expense conversion
- Named decision approvers, quote comparisons, votes, comments, supporting documents, final selections and resulting tasks/purchases
- Custom role templates and temporary/revoked access-plan previews
- Celebration calendar file export (no invitation is sent)
- Guest attendance, shopping wishlist and purchase status
- Searchable 30-module product roadmap
- Interactive landing demos: vendor shortlist, wishlist, budget calculator and date-driven countdown
- Multi-currency budgets, expense forecasts, allocations, savings and alternative scenarios
- Cash/in-kind contributions, sponsorships, installment schedules and manual reconciliation
- Financial CSV reports and existing hosted payment link handoffs
- Vendor discovery samples, professional profiles, proposal comparisons and bookings linked to budgets
- Vendor delivery boards, shared logistics versions, acknowledgements and cross-vendor dependencies
- Shopping collections, multiple wishlists, merchant comparisons, price targets and owned inventory
- Recorded orders, delivery/return/exchange lifecycles and budget links
- Event outfits, measurements, garment care, fittings and collection tasks
- Browser-local persistence and JSON export

The initial profile, tasks and inspiration cards are demonstration content. Other directories start empty. Reset and export controls are in My bridal profile.

## Prototype boundaries

Core wedding workspaces remain a single-user browser-local prototype. The integration hub now has server-side provider adapters: live Wikimedia inspiration discovery; credential-dependent Google OAuth, Places venue discovery, Calendar refresh, Gmail sending and Stripe hosted contribution checkout. Provider sessions, encrypted tokens, snapshots and receipts use configured Upstash Redis. See INTEGRATIONS.md for activation, test coverage and exact limits. These connections do not add shared couple workspaces, participant access control, vendor marketplace settlement, cloud file storage, AI integration or RSVP delivery. Without configured provider credentials, Google and Stripe controls remain disabled. Task attachments are limited to three files of 200 KB each and remain in browser storage. Approvals and discussion are self-recorded; local history is not an immutable audit log. Roadmap modules distinguish interactive screens from planned features. Shopping estimates can be explicitly linked to Budget; external order records create one linked expense without inventing payment. Project base currencies and manually entered exchange-rate snapshots are supported. Clearing browser storage removes records; exports are manual backups without an import flow. See `PART-VI.md` for shopping and wardrobe behavior, `PART-V.md` for vendor workflows and marketplace boundaries, `PART-IV.md` for financial calculations and provider boundaries, `PART-II.md` for scheduling and allocation behavior and `PART-III.md` for collaboration workflows and access-plan boundaries.

Google Fonts enhance typography when a network connection is available; local fallback fonts are provided. All application behavior and the palette image are local.

## Suggested next implementation

Move the data model to a database with authenticated wedding workspaces, membership roles, access enforcement and server-authenticated activity records. Add cloud file storage, collaborator invitations and durable reminder jobs before connecting payment providers or live vendor calendars. Keep the bridal identity independent of wedding projects so pre-engagement preparation survives project activation.

Part VII adds wedding website, guests/RSVPs, stationery and seating tools. See PART-VII.md for workflows and current integration boundaries.

Part VIII adds universal registry records, gifts, fund pledges, inventory integration and public website embedding. See PART-VIII.md for the production boundaries.

Part IX adds optional Beauty & Self-care and Marriage & Home Preparation spaces. See PART-IX.md for local privacy, scheduling and integration boundaries.

Part X adds Wedding-Day Control Room and Memories & Closeout. See PART-X.md for workflows and explicit live-service boundaries.

The shared integration layer connects all modules through search, canonical relationships, activity, versioned files, calendars, offline day packs and regional preferences. See CROSS-PLATFORM.md for behavior and remaining backend integrations.
