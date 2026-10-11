# FURBRIDES

A responsive bridal ecosystem prototype built around a persistent Aspiring → Expecting → Engaged journey. The public landing page is `index.html`; the personal workspace is `journey.html`, with its dashboard named Central. Saturated magenta, orange, teal and violet come from the supplied palette reference. The landing page includes generated campaign imagery, a scalable petal-heart logo, scroll reveals, subtle floating animations and reduced-motion support. See `assets/GENERATION.md` for visual provenance and the generation prompt.

## Run locally

Requires Node.js 18 or later. No dependencies are required.

```sh
npm run dev
```

Open http://localhost:4173. Run `npm run check` for JavaScript syntax checks.

## Vercel deployment

Import `Astercodes/Furbrides` into Vercel and select the `main` branch. The checked-in `vercel.json` configures the static build and `dist` output automatically. No environment variables or dependencies are required. Existing Vercel Git integrations deploy when `main` is pushed.

## Included features

- Central with live summaries and fluid chapter switching
- Bridal profile, date, location, budget, style and traditions
- Inspiration concept collections
- Tasks with completion and filters
- Expense records with remaining-budget calculations
- Contact directory, guest attendance, shopping wishlist and purchase status
- Searchable 30-module product roadmap
- Browser-local persistence and JSON export

The initial profile, tasks and inspiration cards are demonstration content. Other directories start empty. Reset and export controls are in My bridal profile.

## Prototype boundaries

This is a single-user, browser-local prototype, not a production service. There is no authentication, server database, collaboration, messaging, payment processing, vendor marketplace, image upload, AI integration or RSVP delivery. Roadmap modules clearly distinguish interactive prototype screens from planned features. Shopping records do not automatically become budget expenses. Currency is USD. Clearing browser storage removes records; exports can be retained as a manual backup, but import is not implemented.

Google Fonts enhance typography when a network connection is available; local fallback fonts are provided. All application behavior and the palette image are local.

## Suggested next implementation

Move the data model to a database with authenticated wedding workspaces, membership roles and access enforcement. Add image storage, invite flows and activity history before connecting payment providers or vendor integrations. Keep the bridal identity independent of wedding projects so pre-engagement preparation survives project activation.
