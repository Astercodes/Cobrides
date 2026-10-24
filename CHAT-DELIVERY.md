# Chat delivery and live updates

Run supabase/chat-notifications.sql after chat-tools.sql, planning-email.sql and decision-notifications.sql. Repeatable; no existing messages are removed. Adds personal mute/email controls, coalesced bell alerts and a user-owned realtime invalidation signal. Only the signal table is published; messages, files, participants and poll votes remain behind RPC permissions.

Message inserts queue one alert per conversation/recipient, excluding sender, muted and inactive participants. Alert bodies contain no message text. Viewing the chat advances the read watermark, hiding handled alerts. Bell dismissal does not pretend the conversation was read. New messages reset that conversation's alert.

Conversation tools > Alerts persists personal controls across devices. Daily message email requires conversation email_unread=true, global email_opt_in=true, messages category enabled, verified address, unread messages, current access and no mute. Existing daily worker/time-zone/quota/bounce controls remain authoritative; no immediate email is sent for every message. Email consent is never enabled by this migration.

chat-live.js subscribes with the current session to own cb_chat_signals row, renews tokens and reconnects with backoff. Authorized RPCs fetch content. Existing five-second chat polling and one-minute bell polling remain fallbacks. Reconnect reloads the latest history; old messages remain paginated. Logout stops sockets.

Checks cover RLS and removal, real account-owned read/mute controls, email consent, category migration repeatability, private payloads, notification routing, websocket reconnect/token lifecycle and mobile tools. UI checks use mocked sessions; delivery workers are tested without sending real mail.
