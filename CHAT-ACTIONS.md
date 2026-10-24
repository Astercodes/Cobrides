# Message actions

Install supabase/chat-actions.sql after chat-notifications.sql, chat-tools.sql, task-board.sql and shared-decisions.sql. No messages are moved or copied automatically.

A participant who can edit planning can use Take action beneath a message to create one shared task and one decision proposal. The form starts blank and requires explicit review confirmation. Task assignees and decision approvers may be outside the chat; their existing record permissions remain authoritative. No private attachments or conversation text are implicitly added.

Creation uses project/thread locks, account-owned idempotency keys, payload comparison and a unique message/kind constraint. Retry after an uncertain response returns the original action; altered payloads and concurrent duplicate actions return PT409. Notifications use the existing task/decision triggers. The chat receives a private live invalidation signal on creation.

History shows linked records only to viewers permitted to read each target. Source links require both target access and current chat participation. Removal from a chat hides the source while preserving legitimately assigned work. Task details and decision detail pages include source links when allowed. Source URLs load the selected message in context; task links open a task detail dialog and the correct shared wedding workspace.

Tests exercise access isolation, explicit review, atomic retries, duplicate and cross-thread rejection, decisions/approvals and source revocation, plus mobile forms, failed-send retry and existing chat/task/decision flows. UI tests use mocked sessions, not production wedding data.

Vendor and expense linking require their shared record backend and remain a later step.
