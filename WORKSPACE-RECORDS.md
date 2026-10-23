# Record-based workspace saving

Run `supabase/workspace-records.sql` after the cloud/file/storage-recovery migrations, then deploy the matching client. The migration is transactional and rerunnable. No new environment variables or service-role credentials are needed.

## Compatibility and migration

The existing `cb_workspace_states` row becomes a small revision head (`{"cbRecordStore":1}`). Its prior whole-workspace payload is retained until the first complete record save commits. The first new-client save stages every record, validates file references, inserts the records and changes the head in one transaction. The existing backup trigger preserves the prior legacy payload. It never clears existing data first.

Old clients can continue saving unmigrated workspaces. Once migrated, an old whole-workspace save is rejected with an instruction to refresh; it cannot overwrite the record store. Do not rerun the older storage-recovery migration after this migration, because that older script replaces save/recovery functions. If necessary, rerun workspace-records.sql afterward.

## Records and transport

Top-level and nested object structure is represented by object/array markers and individual values. Entries in arrays (guests, tasks, inspiration, purchases and similar collections) are separate records. Unique string IDs provide stable keys; duplicate/missing IDs use positions without dropping entries. Record order, nulls, empty collections and the personal/demo envelope survive round trips. JSONB property order does not cause unchanged records to be resent.

Only changed/new/deleted records are staged. Requests contain at most 200 changes and about 600 KB of JSON. One record is limited to roughly 550 KB; large uploaded content belongs in private Storage. There is no 19 MB workspace save check on the client, and record storage does not aggregate the full workspace into one database payload. The upload allowance remains separate. The staging-count bound is 1,000,000 changes per transaction, not a promise of unlimited storage or platform capacity.

The server checks the expected total count, then atomically publishes the staged changes under the account file lock and current workspace revision. An incomplete batch changes no live data. A stale revision changes no live data. Committed retry IDs return the original result, so an interrupted acknowledgement can be retried safely. Upload retry metadata expires after 30 days; abandoned staging expires after seven days during later saves.

The browser still assembles the workspace for the current UI. This is record-based persistence, not a full conversion to server-side pagination in every feature. Very large collections can still affect browser memory, rendering and load times.

## Device saving and recovery

IndexedDB stores the device cache, durable outbox and save retry token using owner/workspace keys. New UI startup uses the verified cloud `initialData` directly; exceeding localStorage capacity cannot silently replace it with an empty workspace. Writes made while a save is finishing stay queued. If IndexedDB is unavailable, cloud saves can continue, but users are warned that a durable device copy could not be made.

Database versions use revision intervals. Updating one record closes only that record's previous version. Existing recovery checkpoints reference these intervals; new recovery checkpoints keep small head markers. Restoration supports both historical whole-workspace backups and record-based checkpoints, retains the displaced current revision, validates files and checks the displayed current revision.

File reference protection includes current and historical records. History pruning first expires backups, then removes closed versions older than 30 days only when no retained checkpoint needs them. It runs before the existing opportunistic file cleanup. File objects are still removed through the Storage API; this migration does not directly delete Storage metadata. Backups remain within the same project; independent disaster recovery remains a separate operational requirement.

## Validation

- `node --test workspace-records.test.cjs cloud-storage.test.cjs` verifies codec/deltas and the cloud queue.
- `CB_PGLITE_PATH=/path/to/pglite/dist/index.cjs node --test workspace-records.sql.test.cjs` executes actual SQL twice against isolated PostgreSQL fixtures, tests migration, RLS, incomplete saves, stale saves, idempotency, legacy/record recovery, and a workspace above 19 MB.
- `CB_FAKE_IDB_PATH=/path/to/fake-indexeddb/build/cjs/index.js node --test record-sync.test.cjs` exercises the actual client scripts with IndexedDB and a mocked authenticated transport, including paginated large-workspace reads, in-place UI edits, account isolation, interrupted acknowledgements and stale devices. Optional-runtime tests explicitly skip if their runtime is absent.

Live signed-in account/device verification is still required after deployment. The SQL fixtures reproduce roles and row-level security; they do not constitute a full hosted Supabase integration test.
