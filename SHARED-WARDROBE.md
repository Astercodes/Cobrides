# Shared wardrobe and styling

Open **Wardrobe & styling → Team wardrobe**, or **Team wardrobe** in the invited collaborator workspace. Individual personal outfit cards also offer **Share with team**. The review copies only the outfit title, wearer label and style brief; personal measurements, photos, private notes and financial records are excluded. Existing personal outfits stay private until explicitly shared.

## Activate

Run `supabase/shared-wardrobe.sql` after the existing collaboration/access, celebrations, shared-vendors and shared-shopping migrations. A ready-to-run copy is supplied as `C:\Users\ayeni\Downloads\cobridey-shared-wardrobe.sql`. The migration can be run again and preserves existing records.

## Permissions and saving

- Authorized wedding managers maintain outfit plans, audiences, shared shopping-piece links and appointments.
- Assigned wearers/coordinators update progress only. Selected readers cannot modify records.
- Event-linked outfit access also requires current celebration access. Sharing an outfit does not add anyone to an event, vendor workspace or shopping list.
- Each shopping piece and designer name is separately permission checked. No shopping costs are returned by this workspace.
- Membership removal, expiration, event restrictions, and archival are checked on every RPC. Tables and private helper functions have no direct authenticated grants.
- Saves use project-level locking, expected revisions, exact retry IDs and version history. Changed retries and stale revisions fail instead of overwriting another edit.

## Scheduling

Manual collection dates and dates relative to the selected celebration are supported. Relative collection targets follow the celebration's current date. Fittings, alterations, collection and garment-care appointments store local start/end times plus an IANA time zone and absolute instants. Active appointments cannot overlap for the same outfit, wearer or coordinator. Cancelling frees the slot; reopening and changing assignments recheck overlaps. Appointments are not automatically booked with a designer or pushed to external calendars. Progress changes do not create payments or change shopping orders.

## Validation

Set `CB_PGLITE_PATH` and `CB_PLAYWRIGHT_PATH`, then run `npm run test:shared-wardrobe`. Tests cover SQL replay, permissions, private field rejection, event/shop isolation, dates/time zones, overlaps and reassignment, retries/conflicts, revoked access, and mobile forms. Real-account cross-device testing remains deferred at the user's request.
