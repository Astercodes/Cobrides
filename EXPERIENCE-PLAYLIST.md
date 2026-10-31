# Shared celebration music

Wedding Experience → Team experience plan → Music & song order. Each celebration has an independent ordered playlist and do-not-play list. Add titles, artists, moments, local times, HTTPS reference links and shared instructions. Reorder, edit or remove songs, then save the reviewed playlist together. A private personal playlist is not automatically published or overwritten.

Current event readers can view; current event writers can edit. Archived weddings are read-only. The server checks both event revision and playlist revision under the project lock. Exact request replay is idempotent, changed retries are rejected, conflicting edits stay in the browser for copying before an explicit refresh. The table, request records and version history have RLS and no direct client grants. All user-supplied text is escaped in the interface, and sign-out removes the open playlist.

This is music planning and source linking, not streaming, public-playback licensing, DJ dispatch or live equipment control. Songs do not automatically execute or modify run-of-show cues. No financial records or messages are created.

Activation: run supabase/experience-playlist.sql after shared-experience.sql. Additive and rerunnable; preserves existing personal songs and team service records.

Validation: native SQL permission, invalid input, stale event/playlist, exact retry, ordering, archived and anonymous checks; mobile UI ordering, do-not-play, network retry, conflict retention, reader controls, close/reset and overflow checks. Live account/device tests remain deferred by the user.
