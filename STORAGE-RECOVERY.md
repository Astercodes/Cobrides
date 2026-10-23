# Storage allowance and recovery

## Activate

Run `supabase/storage-recovery.sql` in the Supabase SQL Editor after the existing account/cloud/file migrations. It is transactional and rerunnable. Deploy the matching client immediately afterward; refresh any already-open sessions so their uploads reserve space first. No service-role secret or new Vercel variable is needed. Existing file reads remain available, and accounts already above the allowance retain their files.

## Behavior

- Each account has 500 MiB (524,288,000 bytes) for private uploads, shared across inspiration, documents and memories. The existing per-file maximum remains 20 MiB. Existing objects and live upload reservations count toward the allowance. Reservations expire after one hour if the upload does not materialize. Uploads fail before transferring bytes when space is unavailable; the original input is retained.
- Space is reserved transactionally under an account lock. Storage insert policies require an owner reservation and matching server upload metadata (`size` or `contentLength`). Standard binary uploads are used; multipart/resumable upload protocols are not enabled here. Existing immutable paths are deduplicated, with no overwrite policy.
- Saving validates durable private file references against the signed-in owner and existing objects. Missing files fail the save without discarding the browser outbox. Account locks coordinate saves, reservations, cleanup claims and delete checks.
- A database trigger preserves the prior workspace version, at most once every 15 minutes. It retains up to 20 versions per workspace for up to 30 days; pruning occurs during subsequent saves/maintenance. Restoration explicitly keeps the current version, validates the requested backup and compares the current revision before replacing anything. Personal/demo envelopes are restored together because they share one workspace record.
- Settings → Storage & recovery opens an account-owned version list and usage indicator. Unsaved/conflicting edits block restoration. Restoration reloads the workspace only after server confirmation. Sign-out removes its UI.
- Cleanup runs opportunistically once per signed-in page and can also be requested from Storage & recovery. Each batch is limited to 50 files. There is no unattended cron for inactive accounts. Candidates must be unreferenced by every current workspace and every retained backup, and at least 30 days past creation/last saved use. Deletion is performed through the Supabase Storage API, never by deleting `storage.objects` rows in application SQL. Storage RLS rechecks the claim and references at deletion time. Interrupted batches can be retried.
- File cleanup removes expired ledger entries; expired backup pruning is owner-scoped. No other account's records are touched.

## Verification

`node --test storage-recovery.test.cjs file-storage.test.cjs cloud-storage.test.cjs auth.test.cjs auth-session.test.cjs` tests client behavior, retention of failed uploads/drafts, Storage API paths, restoration preconditions and account separation.

`CB_PGLITE_PATH=/absolute/path/to/pglite/dist/index.cjs node --test storage-recovery.sql.test.cjs` runs the actual migration twice against isolated PostgreSQL via PGlite, using fixture auth/storage schemas and real RLS roles. It exercises quota accounting, owner restrictions, metadata checks, missing references, backup restore, stale revisions and cleanup protection. The SQL suite skips explicitly when the optional test runtime is absent; PGlite is not a production dependency.

Complete a live signed-in small-image upload and restore after activation. The fixture database does not reproduce every hosted Storage API version. If a hosted upload fails its metadata policy, retain the original and inspect the error before changing policy; do not weaken owner or quota checks.

## Disaster recovery boundary

These are application recovery versions in the same Supabase project, not an independent disaster-recovery backup. They do not protect against loss of the entire project. Configure Supabase database backups/PITR appropriate to the hosting plan and a separate private Storage-object backup, then rehearse a restore into a separate project. Database-only backups do not contain uploaded file bytes. No claim is made that an off-site backup or full-project restore has been configured.
