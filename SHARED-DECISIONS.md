# Shared decisions and authenticated approvals

Requires collaboration-access.sql. Migration: supabase/shared-decisions.sql.

Authorized wedding editors can create proposals with two to eight options, optional quotes and currency, a deadline, and one to twenty active accepted approvers. Editors and named approvers can read the proposal; unrelated collaborators cannot. Each approver responds only as the signed-in account. Agreement is computed by the server: every requested approver must approve the same option. A preference alone is not approval.

Each content edit increments the proposal version and requires fresh approvals. Old option details, quotes, authors, responses and timestamps remain in version history. Comments are account-owned, escaped in the UI and idempotent under retries. Stale content or approval requests return PT409. No custom retry SQLSTATE 40001 is used.

Membership expiry, removal, archived projects and custom access restrictions are checked on every operation. The browser cannot write directly to proposal, response, version or comment tables. Role-based edit permissions do not let planners approve on another person's behalf.

Lists use a stable sequence cursor (30 proposals per page); discussions load 50 comments at a time. Screens include refresh controls, quote comparison, requested-approver statuses and version history. Personal/example records are not automatically shared. No external emails are sent by this module. Decision attachments, downstream task/purchase creation and decision-specific notification delivery remain separate follow-up work.

Validation: isolated multi-account database tests cover access boundaries, duplicate retries, conflicting approvals, consensus, changed quotes, preserved evidence, stale revisions, comments, expiry, removal and archives. Browser tests cover proposal creation, own approval payloads, project-switch protection and 390px/1440px layouts.

Invited collaborators and professional accounts can use decisions.html?project=PROJECT_ID, linked from the shared wedding workspace, without creating a personal bridal workspace. The login return allowlist preserves this route. Activated in production Supabase on 2026-10-24; SQL editor reported Success. No rows returned.
