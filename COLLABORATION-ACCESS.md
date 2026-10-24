# Shared stakeholders and enforced access

Installed in production Supabase on 2026-10-24 through the authenticated SQL editor; the editor reported Success. No rows returned.

The migration adds shared contact records, owner-controlled custom role restrictions, per-member role assignments and optional access expiration. Base roles continue to cap available privileges. Custom roles narrow planning edits, event visibility, financial visibility and invitation management. A financial permission additionally requires the existing financial-access setting.

Only wedding owners create or assign access roles. Managers can add shared contacts. Other teammates see only their own linked contact. Account links are derived from verified emails and accepted membership within that wedding; the directory cannot enumerate unrelated accounts. Removing a member unlinks the retained contact, and no contact grants access by itself. Personal contacts are copied only when selected explicitly.

Expired access is checked in project, task, event, chat, attachment and background notification paths. Queued invitation email is cancelled if the sender loses invitation access. Owner access is never removed by these custom restrictions. Restoring a member's expiry/base role does not delete contacts or conversations.

All shared mutations use permission-checked RPCs and revision checks. Stale changes return PT409, not transaction-retry SQLSTATE 40001. Migration is repeatable and preserves existing records. No backend keys are exposed to the browser.

Validation: 40 passing database/browser checks across the new access layer, invitations, private chat and existing shared planning. Browser checks cover contact creation, selecting personal contacts, assigning roles/expiry, account/project switches, and 390px/1440px layouts. These are isolated test accounts; a real two-account production acceptance test remains appropriate before launch.

Backup migration: supabase/collaboration-access.sql. Re-running old migrations after this one can replace access functions; re-run this migration last if restoring the schema.

This change does not implement shared decision voting, chat polls/pins, message search or messaging email notifications. Those are separate remaining communication features.
