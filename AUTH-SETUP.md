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
3. Enable Supabase email authentication and configure production SMTP. Both signup confirmation and magic-link email templates must include `{{ .Token }}` because CoBrides asks users to enter their emailed code.
4. Set the Supabase Site URL to `https://furbrides.vercel.app`. Allow `https://furbrides.vercel.app/auth-callback.html` as an application redirect URL. Add exact localhost callback URLs only for local development.
5. Create a Google web OAuth client and enable the Google provider in Supabase. Put the Google client ID and secret in Supabase's provider settings. The Google Console authorized redirect URI is the callback shown by Supabase, normally `https://YOUR_PROJECT_REF.supabase.co/auth/v1/callback`. This differs from the separate YouTube social-connection callback `/api/social`.
6. Redeploy Vercel. Test signup with an email code, returning-user login, Google signup/login, expired codes, invitation email matching, denied admin access, sign-out, and switching between two accounts.

The Supabase project and Google app are not configured yet, so real signup and Google authorization cannot be exercised here. The forms do not fabricate users or sessions. When unconfigured, workspaces redirect into account access and signup/login clearly report that access is unavailable.

## Deployment scope and next backend work

This is the mandatory account-entry foundation. The main bridal and professional planning records still require database persistence and account-bound migration; they are currently isolated by verified user ID in browser storage. This browser guard handles navigation and startup, not database authorization. Database permissions are enforced through Supabase RLS for profiles and the shared workspace.

The subscription table is read-only to authenticated clients, and its entitlement check requires a paid active period covering the current time. No checkout, charge, verified renewal webhook, or full module-level paid-access enforcement is claimed. Connect the chosen payment provider and enforce these rules on protected data operations before selling subscriptions.

References: [Supabase email OTP](https://supabase.com/docs/reference/javascript/auth-signinwithotp), [Google sign-in](https://supabase.com/docs/guides/auth/social-login/auth-google), [PKCE](https://supabase.com/docs/guides/auth/sessions/pkce-flow), [RLS](https://supabase.com/docs/guides/database/postgres/row-level-security).
