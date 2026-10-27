# Shared guests and native RSVP

## Activate

Run `supabase/guest-rsvp.sql` after the installed wedding-projects, collaboration-access, celebration-workspace and wedding-publication migrations. A ready-to-run copy is at `C:\Users\ayeni\Downloads\cobridey-guest-rsvp.sql`. Migration replay preserves existing households and answers. No email/SMS is sent by installation or by creating an invitation.

## Flow

Open **Guests & RSVPs → Shared guests & invitations**, or **Guests & RSVPs** in the invited collaborator workspace. Wedding managers can:

1. Share selected celebration basics from their personal wedding with the planning team. Only names, dates, times, venues and dress codes are copied, using restricted team visibility; financial/logistics fields stay private.
2. Add named households, or choose **From my guest list** to review an existing household. Imported health/contact notes are excluded. Select each named guest's eligible shared celebrations.
3. Save the household and copy its private invitation URL. Share it with that household using the user's chosen communication channel.
4. Review replies, meal preferences and optional dietary/accessibility requirements. The open roster refreshes every twenty seconds, or immediately via Refresh responses.

Guests open `/rsvp.html#<private-token>` without creating an account, then respond for their named household and eligible events. The public wedding website's native RSVP button also allows entering the private invitation link/code. External RSVP URLs remain supported when explicitly configured. Reply links do not confer collaborator accounts or project access.

## Access and integrity

- Only current `write` managers access the shared guest roster. Financial access is neither granted nor required.
- Public views return only household guest names, their selected celebration basics, deadline and that household's existing answers. Contact details, private planning notes, project IDs, tokens, logistics, other households and financial records are excluded.
- Tokens contain two random UUID values without hyphens. Revocation/rotation and project archival immediately invalidate guest access; rotation preserves answers.
- RSVP deadlines are inclusive UTC dates. Up to 50 successful response updates per household per 24 hours are accepted; exact retries are returned before quota checks.
- Project/household locks, expected revisions and exact retry journals prevent duplicate or stale saves. Responses are accepted only for the complete, unique set of named guest/event pairs. Guests cannot add people or invite themselves to another celebration.
- Roster edits retain responses for still-eligible guest/event pairs. Removed entries are preserved in restricted history. Named additional guests can be added by managers; guests cannot expand their household themselves.
- Tables, histories and internal helpers have no direct anonymous/authenticated grants. Public RPCs expose only token-scoped operations. The public API uses the anonymous publishable key, no user session or service-role secret, and sends tokens in POST bodies. Responses are not cached and invitation pages use no-referrer/noindex.
- New personal guest records stay personal until explicitly reviewed and shared. Existing personal RSVP checklists are not silently merged with the shared roster.

## Validation

Set `CB_PGLITE_PATH` and `CB_PLAYWRIGHT_PATH`, then run:
`node --test guest-rsvp.sql.test.cjs guest-rsvp.api.test.cjs guest-rsvp.ui.test.cjs`

Covers role isolation, household/event privacy, retries/conflicts, eligible-event enforcement, deadline/revocation/rotation, retained answers, replay, archive/removal, public API validation, mobile guest replies and reviewed personal imports. Real-account/device tests remain deferred at the user's earlier request.
