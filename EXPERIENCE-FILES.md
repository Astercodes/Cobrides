# Service files and references

Team experience plan → a service card → Files & references. Coordinators explicitly confirm sharing a newly uploaded menu, production brief, image, document, audio or video reference. Each service accepts up to twenty active files; the existing 20 MB per-file limit and account file allowance apply. Personal workspace media is not automatically published. Existing files remain immutable and content-addressed in the private cb-documents bucket.

Listing and file-read policies check current celebration access, including expiry and restricted events. Only current celebration writers can share or remove links. Attaching requires an own-account upload, verified server-side MIME/size, unchanged event/service revisions and no cleanup claim. Upload/link retry state reuses the uploaded path and request ID; exact server retries do not duplicate links or resurrect a later removal. Separate removal requests check attachment revision. Archived weddings are read-only.

Downloads and image/audio/video previews reauthorize, request a 60-second signed URL, and fetch the file without browser caching. No signed URL enters saved wedding records. Blob URLs are revoked when changing preview, closing or signing out. A signed URL already issued can remain usable until its short expiry; downloaded copies cannot be revoked.

Removing a link does not delete the original. Active links protect the object from unused-file cleanup, and removed links retain protection for thirty days. Other private/shared references continue to protect it through the existing cleanup chain. A queued upload whose sharing is cancelled remains an own-account upload and follows existing unused-file recovery rules.

Activation: run supabase/experience-files.sql after shared-experience.sql and the existing file-storage/recovery migrations. Additive and rerunnable. Does not alter existing menus, vendor records, payments or permissions for unrelated files.

Validation uses real native project/experience/storage RLS fixtures for ownership, event readers/writers, expiry, archive, invalid file metadata, cleanup claims, retained references, revision conflicts, exact retry, removal and restoration. Mobile tests cover explicit confirmation, upload reuse after network failure, preview signing/cleanup, no overflow, reader controls and stale-file selection retention. Authentication reset and existing storage/experience regressions are checked. Live device tests remain deferred; no production files are uploaded by tests.
