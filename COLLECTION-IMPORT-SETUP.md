# Account collection import activation

## Pinterest

The new account-backed integration is /api/pinterest. It uses existing Supabase authentication and stores encrypted provider tokens under the user's UUID, rather than the legacy anonymous browser-cookie social adapter. No Upstash account or Supabase service-role key is required for this path.

1. Run Downloads/cobrides-social-collections.sql in a NEW Supabase SQL Editor query. This only creates two private tables, with owner RLS. It is safe to rerun.
2. Create/manage the CoBrides app at https://developers.pinterest.com/apps/ and register this exact redirect URI:
   https://cobrides.vercel.app/api/pinterest
3. In Vercel's existing CoBrides project environment variables add PINTEREST_CLIENT_ID and PINTEREST_CLIENT_SECRET using the app's ID and secret. Put secrets directly into Vercel, not chat.
4. Add INTEGRATION_ENCRYPTION_KEY if it is absent: generate at least 32 random bytes and retain it securely. Do not replace an existing key, because existing encrypted provider connections depend on it. Example local generation: node -e "console.log(require('node:crypto').randomBytes(32).toString('base64url'))". Copy the result directly into Vercel; do not publish it. Existing SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY remain required.
5. Redeploy. In Vision Studio → Discover, choose Connect Pinterest, authorize read access, select the destination CoBrides collection, browse a Pinterest board, review the Pins and import the selection. Settings → Social accounts uses the same Pinterest connection.

Scopes: user_accounts:read, boards:read, pins:read, boards:read_secret, pins:read_secret. Private board visibility depends on granted scopes and Pinterest app access. Trial access may be restricted to permitted test accounts. Obtain the required Pinterest approval before advertising public account imports as enabled for everyone.

OAuth uses a short-lived sealed HttpOnly cookie, a Supabase-owned single-use state row, an exact callback and verified Supabase identity. Provider access/refresh tokens never appear in client JSON or wedding snapshots. Account refresh happens on demand. Boards and Pins paginate in batches of 50; a review is capped at 500 items. Reimport deduplicates source URLs and adds existing items to the selected destination collection without overwriting notes. No automatic background sync or write access to Pinterest is provided.

## Instagram

The live-link importer remains available for individual shared posts. A saved-items export importer now accepts JSON or HTML up to 10 MB, extracts supported Instagram/Pinterest post URLs, and offers a review before saving. It reads files locally and does not upload the complete account export. ZIP archives must be extracted first. Export structure may not include collection names or thumbnails; import destinations are chosen by the user. Private content remains subject to Instagram access restrictions. This is an export import, not live synchronization or an authorized private-saved-folder API.

Instructions shown in Discover point users to Instagram Accounts Center → Your information and permissions → Download/export information → Saved items, JSON when available. The parser tolerates nested string_map_data and saved_saved_media structures, limits depth/work, strips tracking URLs, deduplicates posts and caps a file review at 500 ideas.

## Checks

node --test pinterest.test.cjs board-import.test.cjs link-preview.test.cjs inspiration-image.test.cjs shared-workspace.test.cjs social.test.cjs social-ui.test.cjs
node build.cjs

Automated tests use mocked Pinterest and Supabase responses. Live authorization, secret-board access, revoked permissions and real-device imports still require the registered provider app and production acceptance testing.

Official setup: https://developers.pinterest.com/docs/getting-started/set-up-authentication-and-authorization/
Access tiers: https://developers.pinterest.com/docs/key-concepts/access-tiers/
