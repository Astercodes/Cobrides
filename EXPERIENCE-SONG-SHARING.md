# Saved song to shared playlist

Wedding Experience → Music & DJ → a saved song → Share song with team. Preview and edit title, artist, celebration moment, local time, music link, shared instructions and Play/Do not play choice. Choose a shared celebration and explicitly confirm. Each song is appended to the team playlist; arrange its position under Team experience plan → Music & song order. Save personal song edits before opening the preview.

Only displayed fields are shared. Personal notes, source event IDs, source song IDs, original order and other personal fields are excluded from team records. Personal source notes are not prefilled as shared instructions. The private song remains unchanged. No playback, messages, bookings or payments are triggered.

Owner-only workspace records are read server-side with scoped/legacy precedence and separate demo scope. The native wedding mapping and current write/event access are required. Source hash, event revision and playlist revision protect the reviewed append; the native playlist function validates the final song list. Append, origin mapping and exact-request replay commit atomically under the existing project/workspace locks.

The same personal song/destination pair is shared once. Team edits are never overwritten; deleting a song from the team playlist does not cause the connector to restore it. Changing a private song flags the original connection without changing team records. A different destination ceremony can receive its own copy. Existing unrelated songs and their order remain intact.

Activation: run supabase/experience-song-sharing.sql after workspace-records.sql, shared-experience.sql and experience-playlist.sql. Additive and rerunnable. No automatic bulk import or historical publication.

Validation: native SQL covers owner-only source access, safe fields, explicit confirmation, stale playlist conflicts, atomic append/replay, no duplicates, team edit/deletion preservation, scoped source changes, demo separation and raw/helper/anonymous denial. Mobile tests cover edited previews, destination changes, exact retries, privacy, source preservation, conflict retention, close/reset and overflow. Live account/device tests remain deferred.
