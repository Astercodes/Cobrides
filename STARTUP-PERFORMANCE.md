# Portal startup performance

The portal still verifies the signed-in account, profile and latest cloud workspace before executing application scripts or showing wedding data. No cached-session bypass was added.

Changes:
- Concurrent `current()` calls for the same token and logout generation share an in-flight verification. Later calls still verify normally; logout clears identity and invalidates late responses as before.
- For a browser holding a session token, authenticated script preloads start before verification finishes. Preloading downloads code without executing it; script dependency order is retained.
- Record snapshots retain the selected revision filter and fetch up to four pages concurrently after the first page. The complete decoded baseline is preserved for later saves.
- Private media hydration deduplicates references, verifies the account once and signs files in bucket batches of up to 100 paths, with at most three requests in flight. Responses remain account-scoped and are rejected after reset/account changes. Saving still uses durable file references, never expiring signed URLs.

A 221-file fixture uses four signing requests and one verification; 25 simultaneous session checks use one verification. These are request-count tests, not a promise of a particular live connection speed. Real-account device testing remains deferred by the user.

Validation includes authentication gates and logout, media ownership and round trips, revision-bound paginated loading, and the production-build desktop/mobile portal preview. Batch signing follows [Supabase's private Storage API](https://supabase.com/docs/reference/self-hosting-storage#generate-presigned-urls-to-retrieve-objects).
