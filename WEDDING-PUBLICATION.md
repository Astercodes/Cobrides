# Hosted wedding website publication

Open **Wedding website → Publish & share**. Save the current website as a shared draft, review it, then the wedding owner approves publication. Invited managers can open **Wedding website** in the collaborator workspace to review the saved draft. Planners can prepare drafts from their own website workspace but cannot approve publication on behalf of the owner.

## Installation

Run `supabase/wedding-publication.sql` after the existing wedding-projects and collaboration-access migrations. A downloadable copy is at `C:\Users\ayeni\Downloads\cobridey-wedding-publication.sql`. It is safe to rerun and does not alter private planning records. No new provider credentials are needed; the public endpoint uses the existing Supabase publishable key.

## Publication lifecycle

- One hosted publication per shared wedding project; a randomly generated 64-character token identifies the website.
- Draft saves do not change the guest-visible snapshot. Publishing replaces the approved snapshot at the same link.
- Unpublish withdraws the hosted snapshot. Replace guest link invalidates the previous hosted token. Archived projects are unavailable publicly.
- The public API uses no user session or service-role key and returns only the published snapshot. It cannot enumerate websites. API responses disable caching and indexing.
- Existing legacy `celebrate.html#v1...` snapshot links remain self-contained. They cannot be remotely withdrawn; new share controls produce hosted links instead.

## Data and photos

Server-side validation accepts only the public website field schema: couple names, story, selected celebration details, gallery, approved public registry wishes, contact/dress/travel/FAQ text and theme. Guests, payments, private conversations, documents, measurements and unknown nested fields are rejected. Public image fields reject private Storage URLs and durable file references.

When the signed-in editor saves a draft, private website photographs are copied into resized JPEG data after resolving the owner's file access. This strips source metadata and temporary signed URLs. These separate publication copies become visible only after the owner publishes. Original uploaded files remain private. The complete publication is limited to 4 MB, with up to three gallery photographs, twelve celebrations and sixty public registry wishes. Public external retailer images remain source-linked.

Every write checks current role/project state, expected revision and exact retry identity. A project lock serializes competing edits. Direct table access is denied. Public reads return no project/account IDs, drafts, publication history or guest data. Previously downloaded content or photographs cannot be recalled by unpublishing.

## Scope and validation

This phase provides hosted publication. RSVP remains the configured external form/email flow; shared guest records and native invitation-bound responses are the next phase. No invitations or messages are automatically sent.

Run `node --test wedding-publication.sql.test.cjs wedding-site.api.test.cjs wedding-publication.ui.test.cjs celebration-studio.test.cjs` with `CB_PGLITE_PATH` and `CB_PLAYWRIGHT_PATH` configured. Covers draft separation, owner approvals, schema/privacy validation, anonymous access, retries/conflicts, withdrawal/rotation, archive/revocation, mobile review, copied photos and existing snapshot behavior. Real-account cross-device tests remain deferred at the user's request.

## Wedding-name links

Run `supabase/wedding-name-links.sql` after wedding-publication.sql. Existing sites are backfilled with a wedding-name URL such as `/wedding/wisdom-and-levy`; subsequent couples with the same name receive `-2`, `-3`, and so on. The address remains unchanged when draft names change or updates are published. Replacing the guest link reserves the old name and invalidates its route, preventing it from being reused for another wedding. Original token links continue to work until replaced or unpublished. Name-based links are public and guessable; only deliberately published content is returned. No private guest response or planning data is exposed. Vercel and the local preview server route these URLs to the guest website with root-relative assets.

The website's Download a copy control has been removed, and its Desktop/Mobile preview selector uses the brand gradient.
