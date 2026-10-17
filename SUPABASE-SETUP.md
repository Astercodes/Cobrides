# Activate CoBrides shared workspaces

Implemented: separate participant workspace, verified email-code sign-in, bride-owned projects, delegated planners, invitation links for email/WhatsApp/SMS, seven-day expiry, recipient email matching, revocation, member removal, shared responsibilities and project conversation. Invitations are sent using the user's chosen app; no message is sent automatically.

## Setup

1. Create a Supabase project. Run [collaboration.sql](supabase/collaboration.sql) in its SQL editor once.
2. Enable Email authentication. Configure production SMTP in Supabase so invitations and sign-in are usable beyond Supabase's default email limits. In both the Magic Link and Confirm Signup email templates include `{{ .Token }}` as the sign-in code. CoBrides uses code verification, not an email callback link.
3. Add Vercel environment variables `SUPABASE_URL` (your HTTPS project URL) and `SUPABASE_PUBLISHABLE_KEY` (publishable key or legacy **anon** key). Never use a secret or service-role key. Redeploy.
4. Open `/collaborate.html`, sign in with the bride's email, create a wedding project, invite a stakeholder by their email and choose their role. Share the generated link using Email, WhatsApp, Message or Copy link. A planner can invite ordinary stakeholders; only the project owner can grant planner access.
5. The recipient opens the link and signs in with the invited email, then sees their assigned responsibilities and the project conversation. The owner/planner sees all shared responsibilities. Other participants only see tasks assigned to their verified email. All members can read the project conversation, so keep private information out of it.
6. Test with two distinct accounts before public launch: invited acceptance, wrong-email refusal, expiry, revoked invitation refusal, assigned-task-only visibility, owner/planner visibility, removed-member access refusal, and project isolation. Run the SQL checks below in a test Supabase project. The migration has not been executed against a provisioned project in this workspace.

## What is shared

This initial shared workspace contains only responsibilities and team messages explicitly created there. It does not upload the bride's existing private profile, finances, journals, documents or browser workspace. Existing planning records are not automatically synchronized into shared responsibilities. No external payment or provider credentials are required for this workflow.

Status changes are persisted in Supabase and visible when the team refreshes. This implementation does not claim realtime subscriptions or delivered WhatsApp/SMS notifications.

## Security checks

Use a staging project after applying the migration. Run [collaboration-security-check.sql](supabase/collaboration-security-check.sql); its test records are rolled back. Also perform the two-account browser checks above, including revoked sessions and refreshed pages.

References: [Supabase email OTP](https://supabase.com/docs/reference/javascript/auth-signinwithotp), [Row Level Security](https://supabase.com/docs/guides/database/postgres/row-level-security).
