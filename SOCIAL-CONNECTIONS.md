# Social accounts in Settings

The Social Accounts page uses `/api/social` for Pinterest, TikTok, YouTube and eligible Instagram professional-account OAuth connections. Provider credentials and tokens never enter local journey storage. Credentials are configured by the platform owner; users authorize on the provider’s own site. The page does not invent connected accounts when credentials are absent.

Required shared environment variables: `APP_ORIGIN`, `UPSTASH_REDIS_REST_URL`, `UPSTASH_REDIS_REST_TOKEN`, `INTEGRATION_ENCRYPTION_KEY` (at least 32 characters). Register the exact static redirect URI `APP_ORIGIN/api/social` with each provider. `APP_ORIGIN` must be the deployment’s HTTPS origin without a trailing slash.

- Pinterest: `PINTEREST_CLIENT_ID`, `PINTEREST_CLIENT_SECRET`; approved read scopes for account, boards and Pins.
- TikTok: `TIKTOK_CLIENT_KEY`, `TIKTOK_CLIENT_SECRET`; approved Login Kit and `user.info.basic`.
- YouTube: `YOUTUBE_CLIENT_ID`, `YOUTUBE_CLIENT_SECRET`, or existing Google OAuth client credentials. Enable YouTube Data API and approve read-only access. The adapter verifies a returned channel.
- Instagram: `INSTAGRAM_CLIENT_ID`, `INSTAGRAM_CLIENT_SECRET`; approved Instagram Login and `instagram_business_basic`. This is a professional-account adapter, not a personal-account API.
- WhatsApp: shown separately as business onboarding required. No personal inbox connector, embedded business signup or business messaging workflow is claimed or implemented.

Authorize provider apps with their required review and approved scopes before public use. No provider accounts or credentials are currently configured for this project, so live authorization cannot yet be exercised in production. Mocked protocol tests do not establish approval or live provider compatibility.

Connections belong to a secure, HttpOnly browser session with encrypted server storage. This is not cross-device bridal account synchronization. POST actions require same-origin JSON and a session-bound CSRF token. Callback state is single-use and bound to the initiating session. Google uses PKCE. Tokens expire visibly rather than claiming continuing access; users reconnect. Removing a connection deletes its server authorization record; users can revoke app access at the provider as well. Provider-side revocation and unattended refresh are not automated here.

Current account connection does not automatically import content, sync saved posts, publish media or send messages. Those actions require separate capability-specific adapters and permissions. Existing source-link capture remains independently available.

Official references: [TikTok Login Kit](https://developers.tiktok.com/docs/en/login-kit-web), [Pinterest authorization](https://developer.pinterest.com/docs/getting-started/set-up-authentication-and-authorization/), [Google server OAuth](https://developers.google.com/identity/protocols/oauth2/web-server), [Instagram Login](https://developers.facebook.com/docs/instagram-platform/instagram-api-with-instagram-login/business-login/), [WhatsApp business onboarding](https://developers.facebook.com/docs/whatsapp/embedded-signup/).

## Activation checklist for furbrides.vercel.app

1. Create the provider developer apps using the official links above. These are platform-owner applications; brides do not create developer apps.
2. Register this exact callback in each provider application: `https://furbrides.vercel.app/api/social`.
3. Configure the shared encrypted session store and the five shared environment variables listed above in Vercel. Use `APP_ORIGIN=https://furbrides.vercel.app` with no trailing slash. Keep tokens and secrets out of chat and source control.
4. Add the selected provider's client/app ID and secret using its exact environment variable names above. For Google/YouTube, enable YouTube Data API and configure the web OAuth consent/client. Request only the scopes implemented by the adapter.
5. Complete each provider's testing, review and public-access requirements. A development/test app is not necessarily available to arbitrary brides.
6. Redeploy Vercel. Open Settings → Social accounts → Refresh connection status. The selected provider should show Ready to connect and its Connect button should be enabled.
7. Test authorization with an eligible account, provider cancellation, reconnect and disconnect. Verify the account label appears only after the provider callback succeeds.

Without configured provider apps and session storage, Connect actions remain disabled and clearly unavailable. Status-loading errors can be retried. Errors from an available provider appear beside that provider, rather than being hidden above the account grid. This fixes misleading controls; it cannot replace provider registration or approval.
