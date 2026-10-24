# Conversation tools

Participants can search their conversation, pin up to 20 messages, and create single-choice polls. Votes belong to the authenticated account; choices may change until the poll closes. Poll creators and conversation admins can close/reopen polls.

Conversation admins can add accepted, active wedding teammates after acknowledging that earlier messages/files become visible. They can remove participants and hand over administration. The last active admin cannot leave other participants without a handoff. Wedding ownership does not grant access to private chats.

Install supabase/chat-tools.sql after communication-hub.sql and collaboration-access.sql. Migration is repeatable. New tables have RLS and no direct client access. RPCs enforce membership and serialize project/thread mutations in consistent lock order. Removed/expired participants lose message, file, search and poll access.

Checks: shared-chat-tools.sql.test.cjs, shared-chat-tools.ui.test.cjs, existing shared-chat SQL/UI tests. UI checks use mocked accounts; SQL checks exercise authorization with separate authenticated identities.
