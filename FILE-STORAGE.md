# Private file storage

## Activate

1. Run all of `supabase/file-storage.sql` (also copied to Downloads/cobrides-file-storage.sql) in a NEW Supabase SQL Editor query. It is rerunnable, creates three private buckets, and leaves workspace tables untouched.
2. Confirm Success before deploying this change. No new Vercel environment variables or service-role keys are required.
3. Deploy and sign in again. Existing supported embedded attachments migrate during the next confirmed workspace save. Keep the page open until All changes saved.
4. Verify a photo and document on another device. Attempt access from a second account: it must fail. Test loss of connectivity during transfer, retry, and conflicting workspace saves.

## Design

Buckets: cb-inspiration, cb-documents, cb-memories. Owner UUID is the first path component. SHA-256 of file content plus MIME type forms the immutable object name. Allowed types and a 20 MB per-file ceiling are enforced in both the client and bucket configuration. Individual forms may impose lower limits. Task, chat and document attachments allow 10 MB; Vision photos accept 8 MB sources and are compressed before transfer.

Uploads use authenticated requests, retry transient failures up to three attempts, and download/verify the stored bytes before returning a signed link. Progress reports upload, retry and verification stages. These are standard retried uploads, not resumable video uploads. A failed upload must be retried while the original file is still available.

Workspace snapshots persist cb-file:v1 references, not expiring signed URLs. Opening a workspace signs its file references for 24 hours. Reopening the workspace renews them. A tab left open beyond 24 hours must reload to renew private media links. The cloud compare-and-swap remains authoritative. Existing inline source data stays in the pending snapshot until all uploads are verified and the new snapshot is accepted. Failed migrations retain originals; uploaded orphan files may remain and are not automatically deleted.

New Vision, task, chat and document uploads go directly to storage. Existing embedded media anywhere in a snapshot, including registry media, migrate through the same save pipeline. External retailer and inspiration links are not copied or fetched. Files are owner-private: these policies do not yet grant invited collaborators access. Public registry/website exports must not be given permanent access to private account files; a separate explicit publishing workflow is required for those assets. There is no blanket public bucket.

No update/delete policy is granted; immutable objects cannot be overwritten or accidentally removed while referenced by another saved snapshot. Storage cleanup, account erasure and collaborator file grants need explicit server workflows before advertising those capabilities. Retain Supabase backups and monitor storage usage.

## Verification

Run `node --test file-storage.test.cjs cloud-storage.test.cjs auth.test.cjs auth-session.test.cjs sign-out.test.cjs onboarding.test.cjs shared-workspace.test.cjs planning.test.cjs collaboration.test.cjs registry.test.cjs platform.test.cjs vision.test.cjs` and `node build.cjs`.

Tests mock the network and verify migration, byte integrity, references, retries, account scoping and conflict behavior. Production bucket RLS and phone/computer transfers still require the real-account acceptance test after activation.
