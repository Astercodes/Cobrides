# CoBrides provider integrations

## Implemented adapters
- Live inspiration search: Wikimedia Commons API, no credentials required. Results show the source, creator and license reference. Saving stages a canonical source-linked record for review. No license is implied by discovery.
- Venue discovery: Google Places Text Search, server-side key, authenticated searches, 30 searches per account per hour. Places does not confirm wedding availability or prices.
- Google connection: server authorization-code OAuth with PKCE, cookie-bound one-time state, verified account identity, incremental Calendar/Gmail permission requests, encrypted server token storage, refresh and disconnect/revocation. Provider identity is not a new couple collaboration or participant authorization system.
- Google Calendar: primary-calendar read-only full/incremental refresh, paginated results, cancellation ingestion, expired-cursor reset, server snapshot and browser review before creating/updating/removing linked appointments. Source time zones and durations retained. Five-minute refresh is optional while the workspace is open. No background scheduler, two-way publication, recurring-instance expansion or conflict-free automatic overwrite is claimed.
- Gmail: send-only authorization; one reviewed email recipient and explicit confirmation; MIME encoding; server send key prevents duplicate submission; 20 sends/account/hour. Acceptance is not proof of delivery/read. No inbox access or external chat synchronization.
- Stripe: hosted Checkout for one server-configured fixed registry contribution price; authenticated owner, provider idempotency, server-verified return status, signed webhook ingestion and immutable event receipts. No card handling, arbitrary vendor payouts, marketplace settlement, automated financial-ledger fulfillment or refund UI. The price and recipient belong to the configured Stripe account. Start in test mode.
- Manual intake remains available for unsupported provider URLs, files and references. Other provider families are candidates; they have not been represented as connected integrations.

## Activate on Vercel
The user confirmed no provider accounts exist yet. No credentials have been created or substituted. The code can deploy now; credential-dependent controls remain visibly disabled until configured.

1. Create a persistent Upstash Redis database (via Vercel Marketplace or Upstash). Set UPSTASH_REDIS_REST_URL and UPSTASH_REDIS_REST_TOKEN in Vercel. Store sessions, OAuth state, encrypted tokens, sync cursors, and provider receipts server-side. This is not an expiring demo database.
2. Set APP_ORIGIN to exactly https://furbrides.vercel.app (or the final production origin), without trailing slash. Set INTEGRATION_ENCRYPTION_KEY to a securely generated random value of at least 32 characters. Never put secrets in public JS, localStorage, source control or screenshots. Changing this encryption key invalidates existing connections.
3. Create a Google Cloud project and Web OAuth client. Enable Calendar and Gmail APIs. Configure the consent screen and test users. Add this exact authorized redirect URI: https://furbrides.vercel.app/api/integrations?action=callback . Set GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET in Vercel. For public launch, complete Google's applicable consent/app verification requirements. Calendar permission is calendar.events.readonly; Gmail permission is gmail.send; both request openid/email identity.
4. Optional venue discovery: enable Places API (New), configure billing/quota and restrict GOOGLE_PLACES_API_KEY to that API. Store the key server-side. Google Maps original-source links remain attached to results.
5. Create a Stripe account, a clearly labeled registry contribution product, and a fixed Price in test mode. Set STRIPE_SECRET_KEY and STRIPE_REGISTRY_PRICE_ID. The platform owner must ensure the configured recipient and contribution terms are appropriate before enabling real payment collection. Register https://furbrides.vercel.app/api/integrations?action=stripe-webhook for checkout.session.completed, checkout.session.async_payment_succeeded and checkout.session.async_payment_failed. Set STRIPE_WEBHOOK_SECRET. Event signature verification uses the raw body, a five-minute tolerance and timing-safe comparison. Receipts are stored by event ID so delivery retries are safe.
6. Redeploy after setting environment variables. Open Integrations > Synchronize, authorize a test Google account, refresh the primary calendar and review selected records. Authorize Gmail separately. Send a test email to an address you control. Use a Stripe test checkout and verify return status and webhook receipt before enabling live credentials.

## Persistence and boundaries
Provider credentials, sessions, calendar snapshots and receipts have 30-day retention; unused connections expire. OAuth state expires in ten minutes; duplicate-send keys last one day. Browser journey records remain in the existing local data model. Provider authorization does not upload the entire journey, grant collaborator access, or synchronize unrelated private journals. Disconnect revokes Google and deletes the active account tokens and calendar cursor; previously reviewed local appointments remain. Backups may include their source and account email.

Server endpoint: /api/integrations?action=... . Vercel automatically deploys the Node function from api/integrations.js; the static build never copies this server source to dist. Local preview uses server.cjs (PORT may override 4173); provider OAuth needs HTTPS cookies and is intended to be tested on a configured Vercel origin.

## Verification
integrations.test.cjs uses an injected fake provider transport and store: encryption/tamper handling, live-result mapping, origin/CSRF rejection, OAuth cookie binding/replay, scope checks, token refresh, incremental cursor/cancellation/reset, duplicate sends, email header injection, checkout ownership/idempotency, and webhook signature tampering. No real payments or external messages were performed during automated tests. Credential-dependent flows require the activation smoke tests above; mocked tests do not establish provider approval.

## Provider references
- https://developers.google.com/identity/protocols/oauth2/web-server
- https://developers.google.com/workspace/calendar/api/guides/sync
- https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/send
- https://developers.google.com/maps/documentation/places/web-service/text-search
- https://docs.stripe.com/api/checkout/sessions/create
- https://docs.stripe.com/webhooks/signatures
- https://www.mediawiki.org/wiki/API:Search
- https://upstash.com/docs/redis/features/restapi

## Vision Studio assistant
The authenticated vision-assist action uses OpenAI Responses with an allowlist of selected inspiration titles, notes and HEX colors, plus the user’s prompt. Set OPENAI_API_KEY and OPENAI_MODEL in Vercel. It does not read unrelated journey records. Responses are suggestions, not verified matches or actions. See VISION-STUDIO.md for the module and its boundaries.
