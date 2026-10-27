# Shared shopping reminders and updates

Apply `supabase/shopping-notifications.sql` after shared-shopping.sql and vendor-notifications.sql. The migration is repeatable, preserves existing records and uses the existing notification inbox, reminder scheduler and opted-in daily email summaries. Installing it does not send a test email. The setup copy is `C:/Users/ayeni/Downloads/cobridey-shopping-notifications.sql`.

Managers and the currently assigned buyer receive generic responsibility/progress notices, excluding the actor. Other list readers do not receive these operational alerts. Current project/list access, membership expiry, assignment and archival are checked again whenever a notice is read or opened. Old assignment notices disappear after reassignment, and obsolete revision notices are suppressed. Notice text contains no product titles, retailer names, sizing notes, order references or financial metadata.

Deadline types:

- Buy-by dates for Needed or Reserved items.
- Expected delivery dates for Purchased or Shipped items.
- Return windows for Purchased, Shipped, Delivered or Return requested items.

Each uses the recipient's configured time zone and upcoming-three-day/today/overdue phases. Notices deduplicate by item, date, deadline type and phase. Date edits and state changes hide obsolete reminders. Returned, Refunded and Cancelled items stop these deadline reminders. Expected-delivery notices use recorded dates; they do not claim that a carrier has verified a delivery.

The assignments/shared-updates and deadlines preferences apply independently. Existing email opt-in, verified-address requirements and daily-summary cadence remain in force. Current visibility and preferences also filter email counts. No new email provider, API key or messaging channel is introduced.

An operational notice counter increments only for changes to item details, buyer, status or progress notes. Linking a financial expense may advance the item revision but neither generates shopping alerts nor invalidates its operational notices. Project locks, write-request journals and the existing source permissions remain unchanged.

Notification links authorize the exact source before navigating to Team shopping, select its canonical list and highlight the item. Missing or inaccessible items are rejected. Switching weddings clears list/item navigation. Earlier decision/chat/expense/contribution/vendor notification constraint declarations now preserve all installed source kinds; reapply this shopping migration after replaying older notification migrations to restore its latest wrapper/digest integration.

These reminders operate on explicitly shared Team shopping records. Personal shopping/wardrobe data is not scanned or published by this scheduler. A bride can choose which shopping records to share through the existing review flow.

Validation includes audience isolation, generic notice content, status transitions, three deadline types, deduplication, time zones, finance-only revisions, email consent/counts, source navigation, item highlighting, migration replay and access revocation. The shared-shopping and vendor regression runners passed, as did the added focused source/highlight checks. Build and JavaScript syntax checks pass. Live multi-account/device testing remains deferred by the user.
