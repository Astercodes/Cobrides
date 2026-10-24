# Existing records in conversations

Install supabase/chat-record-links.sql after chat-actions.sql. The repeatable migration adds references to existing shared tasks, decisions and celebrations. It never copies record content or grants chat/record permissions.

Use Take action > Link existing record. Search is literal, scoped to the current wedding and returns up to 50 accessible matches. Each message can hold twelve references. Duplicate link requests are idempotent; removing a link keeps the underlying record. Deleted targets are cleaned up by triggers.

History and record detail recheck current record visibility and chat participation. Someone can read a task without seeing its private conversation; someone can read a conversation without seeing a restricted task, decision or celebration. Decisions and task detail screens provide permitted conversation backlinks. Existing live signals refresh linked messages.

Tests cover target/conversation isolation, restricted celebration membership, cross-project rejection, literal search, duplicate requests, unlink/delete behavior and mobile linking/detail/removal. Shared vendor/expense records are not part of this migration: their account-owned storage must gain shared backend permissions first.
