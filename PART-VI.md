# Part VI — Bridal shopping, purchases and styling

## Product discovery

Shopping & commerce includes discovery/collections, lists/inventory and orders/deliveries. Six clearly labelled fictional product examples cover ceremony, cultural attire, accessories, wedding morning and honeymoon inspiration. Category/search filters and a transparent profile-keyword sort demonstrate product discovery without claiming a live marketplace or AI recommendations. Product art is local SVG/CSS and an existing honeymoon image.

Save samples as inspiration. They cannot become real budget expenses or orders. Add a real item with a merchant name, HTTPS product link, category, size, variant, fit notes and price. Merchant comparisons include quantity, landed cost, currency/rate snapshot, observation date, size notes and private personal reviews. Recorded offers at or below an item target trigger a local price alert. Stores are not monitored automatically; reviews are neither published nor verified.

## Lists, costs and duplicate prevention

Create and edit multiple named lists (wishlist, shopping list or owned collection). An item can belong to several lists. List type is an organizational label and does not establish ownership. Items have required/optional priority, a responsible stakeholder, celebration links, manual or relative purchase deadline, quantity, sizing and attachments. Relative deadlines use the selected celebration date or wedding date and recalculate when plans change. Required purchase deadlines have canonical tasks in Planning.

The landed estimate is goods (unit price times quantity) plus shipping and insurance; entered duty percentage applies to that subtotal, entered tax percentage to the subtotal plus duty, then other fixed charges are added. These are user-supplied assumptions, not customs advice or carrier quotes. Every cost keeps its manually entered exchange-rate snapshot. Price comparisons display totals in project currency. Budget compatibility uses current forecast headroom. Real shopping and proposal records lock the project base currency alongside existing financial records.

Duplicate product URLs ignore marketing parameters and fragments. The same product/name, merchant, size and variant is blocked within a project; different sizes or variants are permitted. Existing ownership and active orders also prevent another order for that item. Items can be archived/restored while retaining history; active-order items stay visible. Already-owned items can return to the wishlist if no active order exists. Dashboards count distinct item records, not individual units.

## Orders and financial records

Record an external order from a real saved item. It snapshots quantity, costs and currency, links one canonical budget expense and stores the external order reference. Linking an estimate repeatedly does not duplicate its expense. Converting an untransacted estimate to an order updates that cost; existing financial movements require review in Budget first. No actual payment is inferred. Payment and refund records use the existing finance ledger.

Orders progress through supported states: ordered, processing, shipped, delivered, return requested/returned, exchange requested/exchanged, or cancelled. Updates must follow the lifecycle and use chronological observation dates no later than today. Tracking numbers/HTTPS carrier URLs, expected delivery, origin/destination, return/exchange deadlines, warranty dates, policy notes and documents are recorded manually. A returned/cancelled order cancels its expense/schedules while retaining actual financial history; cash refunds are never invented. Reordering creates a new expense rather than overwriting a past order's cost snapshot.

Delivered, exchange-requested, exchanged and return-requested items count as recorded owned inventory until returned. Ordered/processing/shipped items count as purchased commitments but not received inventory. The budget remains distinct from cash paid. Full delivery tracking, merchant APIs, checkout and automatic price alerts require external services and a backend.

## Wardrobe and styling

Wardrobe & styling supports the bride, partner, bridal party, parents and any stakeholder as a wearer. Outfit plans link celebration, designer/stylist, wardrobe pieces, accessories, photos/documents, dress code, preparation status, collection date and garment-care instructions. Designer conversations reuse the local communication hub. Collection deadlines use canonical Planning tasks. Fittings, alterations, dress collection and care appointments each have a linked task; rescheduling a completed appointment reopens its task, with a guard for completed dependents.

One current measurement profile per wearer stores chest/bust, waist, hips, shoulders, inseam, height, shoe and clothing sizes, units, date and tailoring notes. Switching centimetres/inches converts numeric measurements. Size-system text remains user-entered. Confirm fit with the actual merchant/tailor. Measurements and outfit photos stay in local browser storage with no authenticated per-person access controls.

## Persistence, exports and verification

Legacy shopping records migrate once; earlier purchased items become owned inventory without fabricated orders or payments. Files reuse the existing three-file, 200 KB-per-file limit. Shopping CSV exports items, orders and outfits with spreadsheet formula protection; measurement details and attachment contents are excluded. Full JSON backups include raw local records, including measurements. There is no import or cloud sync.

Model tests cover migration, owned inventory, import-estimate arithmetic, exchange rates, relative deadlines, safe links, duplicate variants, idempotent budget links, immutable order snapshots, returns, reorder isolation, lifecycle validation and sample/owned guards. Browser checks cover collections, multiple lists, forms, price targets, budget/order links, delivery/returns, duplicates, outfit inventory, unit conversion, fitting persistence and responsive layouts. Existing planning, collaboration, finance and vendor tests remain required.
