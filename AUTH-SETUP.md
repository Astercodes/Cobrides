# CoBrides account access

## Implemented

- Signup and login screens, email code verification, Google OAuth with PKCE, and a callback page.
- New workspace visitors enter signup; recognized returning visitors enter login. No workspace application scripts run before a verified email identity and account profile are loaded. Public marketing pages and published wedding websites remain public.
- Bride, collaborator, partner, bridal-party, family, planner, vendor, merchant, venue and guest account types. Account type chooses a starting workspace; wedding-project access comes from server-side membership, not the signup choice. Admin access is not self-service.
- Account-scoped personal workspace storage. Existing `furbrides-v1` and previous professional records are preserved separately; they are not automatically assigned to whichever person signs up first. A controlled migration is still needed for those pre-account records.
- Bride-to-planner invitations, planner-to-bride invitations and invited collaborators in the shared workspace. A planner-owned project's bride invitation transfers ownership on acceptance and retains the original planner as a team member. Later transfer invitations from the former owner cannot replace the bride's ownership.
- Billing policy: plan totals remain NGN 6,000 / 15,000 / 27,000 / 50,000 for 1 / 3 / 6 / 12 months. Access expires at the end of a paid period. Auto-renew defaults off and is an explicit checkout choice; selecting it does not extend access without a successful verified renewal payment.

## Activate authentication

1. Create the Supabase project and run `supabase/collaboration.sql`, followed by `supabase/accounts.sql`, once in the SQL editor. If the collaboration migration was already applied, run only accounts.sql.
2. Set Vercel `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY`. Use a publishable or legacy anon key, never a service-role/secret key in public configuration.
3. Enable Supabase email authentication and configure production SMTP. CoBrides supports both email links (`{{ .ConfirmationURL }}`) and typed codes (`{{ .Token }}`). Include `{{ .Token }}` in signup confirmation and magic-link templates if you want users to receive a numeric code; existing link templates are also supported.
4. Set the Supabase Site URL to `https://cobrides.vercel.app`. Allow `https://cobrides.vercel.app/auth-callback.html` as an application redirect URL. Add exact localhost callback URLs only for local development.
5. Create a Google web OAuth client and enable the Google provider in Supabase. Put the Google client ID and secret in Supabase's provider settings. The Google Console authorized redirect URI is the callback shown by Supabase, normally `https://YOUR_PROJECT_REF.supabase.co/auth/v1/callback`. This differs from the separate YouTube social-connection callback `/api/social`.
6. Redeploy Vercel. Test signup with an email code, returning-user login, Google signup/login, expired codes, invitation email matching, denied admin access, sign-out, and switching between two accounts.

Supabase public configuration is connected. Email-code delivery needs a real-user verification test; Google authorization still requires its provider app setup. The forms do not fabricate users or sessions. When unconfigured, workspaces redirect into account access and signup/login clearly report that access is unavailable.

## Deployment scope and next backend work

This is the mandatory account-entry foundation. The main bridal and professional planning records now use cloud snapshots after applying cloud-storage.sql, with an account-scoped local cache and durable outbox. This browser guard handles navigation and startup, not database authorization. Database permissions are enforced through Supabase RLS for profiles and the shared workspace.

The subscription table is read-only to authenticated clients, and its entitlement check requires a paid active period covering the current time. No checkout, charge, verified renewal webhook, or full module-level paid-access enforcement is claimed. Connect the chosen payment provider and enforce these rules on protected data operations before selling subscriptions.

References: [Supabase email OTP](https://supabase.com/docs/reference/javascript/auth-signinwithotp), [Google sign-in](https://supabase.com/docs/guides/auth/social-login/auth-google), [PKCE](https://supabase.com/docs/guides/auth/sessions/pkce-flow), [RLS](https://supabase.com/docs/guides/database/postgres/row-level-security).

## Cross-device storage

Run `supabase/cloud-storage.sql` once after the account migrations. Bridal and professional workspaces fetch the authenticated account's cloud snapshot before rendering, and save complete planning state through an atomic revision-checked RPC. Table reads use owner-only RLS; direct client writes are revoked. No service-role key is needed.

Edits are saved automatically after a short delay, with an account-scoped local outbox for failed saves. A login/reload on another device loads the saved cloud version. Concurrent stale edits raise a conflict rather than overwrite newer cloud records; the user can download their unsynced changes before explicitly loading the cloud version. Unsynced changes trigger a browser leave-page warning. This is snapshot synchronization, not simultaneous multi-user field merging or live cursor collaboration.

The explicit `/journey.html?demo=amara-tobi#home` route opens a populated Amara and Tobi sample journey for the authenticated account. Sample access no longer depends on matching the earlier demo-seeding email. Personal and demo states are stored in a versioned envelope inside the same owner-protected cloud row; optimistic concurrency covers both, and demo saves preserve personal plans. The demo panel links back to the personal journey. Existing snapshots are upgraded without discarding their personal payload. Existing temporary visitor records and legacy records are preserved separately; they are not automatically uploaded into unrelated accounts. Inline media saved inside the journey is included in its JSON snapshot (20 MB limit); a separate media/object-storage pipeline and general browser-file attachment migration are not included.

A live two-device sign-in test requires running the cloud migration and configuring email delivery. Automated tests cover cross-device rehydration, account isolation, persisted outbox recovery, and stale-revision conflicts; SQL permission checks also need exercising in the deployed Supabase project.

Email links now explicitly target `/auth-callback.html`. A small early return handler on public/account pages also recovers default-Site-URL redirects, removes authentication fragments from the original URL, and forwards them to the callback. Callback tokens are verified with Supabase before any profile or workspace is opened. Links opened in another tab can recover signup profile details from verified user metadata.

## Sign-out behavior

Sign-out immediately clears the current browser tab’s Supabase session, pending invitation and in-progress authentication data, stops cloud autosave, and invalidates other tabs through a shared logout epoch. Late verification or refresh requests cannot persist an older session after that epoch changes. Planning records and the cloud outbox are retained. Supabase session revocation and integration-cookie cleanup run after local removal; if network cleanup fails, login still remains signed out locally and displays the limitation. A fresh explicit email/Google login establishes a new session epoch. Other devices remain signed in unless their sessions are separately revoked.

The designated demo account now opens the Amara and Tobi journey by default on ordinary bridal workspace logins. `/api/account-context` verifies the supplied Supabase bearer token against `/auth/v1/user` before returning the preference; it does not expose the email or grant additional data access. `?workspace=personal` explicitly opens that account’s preserved personal journey. Other accounts retain their personal default. The explicit `?demo=amara-tobi` route remains available.
