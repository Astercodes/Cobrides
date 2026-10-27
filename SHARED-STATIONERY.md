# Shared stationery and curated design collections

## Activate

Run `supabase/shared-stationery.sql` after the existing wedding-projects, celebration-workspace and collaboration-access migrations. A ready-to-run copy is at `C:\Users\ayeni\Downloads\cobridey-shared-stationery.sql`. Existing personal designs are preserved. Re-running the migration preserves shared drafts and approval history. No email, invitation or message is automatically sent.

## Personal Studio

Open **Stationery Studio → Browse design collections**. Ten original collections support invitations, save-the-dates, ceremony programs, RSVP cards, thank-you cards, bridal showers, menus and place cards. The picker previews the current couple's names, lets users keep their current colours, and applies the chosen style without replacing existing wording or venue details. The existing design editor retains editable names/wording and custom colours. Personal exports offer PDF, PNG, JPG, Word and original SVG through the existing format picker.

Collections: Botanical romance, Burgundy rose, Terracotta bloom, Sage herbarium, Ivory letterpress, Modern arch, Art Deco, Midnight gala, Blush silk and Coastal elegance.

## Shared workflow

Use **Shared stationery & proofs** to create a shared draft, or **Share current design** to review and copy one personal design into the shared workspace. Accepted planning managers can prepare and edit designs; the current wedding owner approves the exact proof. Each save increments its revision and clears approval. A linked celebration's revision must still match when approving; date/venue changes invalidate its approved status. Ownership changes also invalidate approval by a previous owner.

Exports recheck current access, revision and approval immediately before generation. Unapproved shared proofs carry a Draft / review-copy banner. Approved shared proofs export without it. Archived designs cannot export; restored or edited designs require fresh approval. Withdrawing approval requires a reason. Private version snapshots and review notes are retained. Existing downloaded files cannot be recalled by withdrawing approval.

## Artwork and formats

Names and text are escaped editable SVG text, not generated lettering. Four floral/romantic collections use original generated botanical artwork; the other designs use native linework and shapes. WebP previews total under 1 MB; exports embed the original PNG art so they do not depend on external image links. Only static public artwork is cached, not users' rendered proofs.

Card artwork is 1500 × 2100 pixels. The stationery-specific PDF exporter creates a 5 × 7 inch page, while Word uses a matching page with embedded artwork. Other existing platform export layouts are unchanged. Long text is wrapped and scaled within a bounded print area; content that cannot fit produces a visible error instead of clipping. PNG/JPG output preserves the complete card appearance. Colour inputs accept strict six-digit HEX values. Artwork prompts and saved asset paths are documented in `assets/stationery/ARTWORK.md`.

## Security and validation

Only current planning managers with any linked celebration's access may read or edit shared designs. Only the current project owner can approve. Raw tables, history and helper functions have no direct client grants. Project locks, expected revisions and exact request IDs prevent stale edits, duplicate sharing and changed retries. Unknown fields, invalid colours, cross-wedding event references and invalid design types are rejected. No vendor/printing account access or public document-sharing permission is inferred.

Set `CB_PGLITE_PATH` and `CB_PLAYWRIGHT_PATH`, then run:
`node --test shared-stationery.sql.test.cjs shared-stationery.ui.test.cjs`

Checks cover manager/owner roles, private access, edit/event/ownership approval invalidation, retries/conflicts, archival, replay, all collections, SVG safety, mobile collection selection, personal wording preservation, embedded original artwork and actual PDF/Word dimensions. Real-account cross-device testing remains deferred at the user's request.
