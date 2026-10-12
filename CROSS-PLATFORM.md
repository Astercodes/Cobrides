# Cross-platform integration layer

The shared layer adds Search & Connected Records, Activity & Notifications, Documents & Files, Unified Calendar, Offline Readiness and Regional Preferences. These sit beside the original thirty modules rather than replacing them. Central and the global header link to the shared tools.

## Connected records and search

The index reads original module arrays and canonical record IDs; it does not duplicate business records or money. It infers links through expense, purchase, order, outfit, fitting, vendor, task, conversation, gift, contribution, event and document references. Additional labeled links connect relationships that cannot be inferred. The dress example links to its canonical expense, recorded order, outfit, registry entry and task; an outfit leads to its fittings, and an expense leads to its sponsorships and payments. Manual metadata links do not allocate funds or create orders.

Search covers original record text and filenames across the current project, with record-type filtering and an explicit include-personal-records option. Documents are not parsed/OCR-indexed. Private preparation, anonymous gift records, private conversation notes, private contributions and identity references are excluded from the default search view. These filters are not authenticated permissions. Results display original records, related records and related activity, and open the corresponding original editor/workspace where supported. Existing received registry gifts now also satisfy their linked shopping purchase task rather than leaving it outstanding.

## Unified activity and notifications

Record revisions produce a deduplicated, project-scoped change feed whenever the user saves. The center combines changes with upcoming/overdue tasks and payment dates, recorded order delivery dates, document expiry reminders and unsent wedding-day alerts. It retains original planning history separately. Notification preferences control categories, in-app channel selection, day/week digest grouping and overnight quiet hours. Read state is independent of activity history. Quiet hours mute the header attention indicator but leave records accessible.

Email, push and SMS selections are preferences for planned integrations, not active delivery. Digests group records in the open app; there is no scheduled background sending. Revision fingerprints detect local changes and are not cryptographic signatures or immutable audit logs.

## Documents and files

The library stores metadata, optional local files (PDF, text/CSV, PNG/JPEG/WebP, DOCX/XLSX, up to 500 KB), version notes, previous versions, current-version selection, linked original owners and expiry/review dates. Existing module attachments are shown by reference rather than duplicated. Version snapshots preserve classification/access-plan metadata. File storage has a conservative browser-storage guard.

Classification and role selections are access plans, not enforced permissions or secure sharing. Identity references accept metadata only; uploading identity files is blocked. No public file-sharing URL is created. Full journey/device backups contain private files and metadata; public wedding website exports do not.

## Unified calendar

The calendar combines celebrations, planning dates, timed fittings, shared/private preparation, operational schedules, payment obligations, recorded order delivery dates and calendar holds. Linked fitting/preparation entries are merged with their tasks to avoid duplicate calendar entries. Project and per-celebration IANA zones support destination events. Timed entries are converted for cross-zone shared-resource conflict checks; invalid/ambiguous daylight-saving times are flagged. Calendar holds reject conflicts for selected people. Existing source-module conflicts are reported rather than silently rescheduled.

Stakeholder and personal-record filters control the view and exported ICS file. UTC timed exports preserve instants; all-day dates remain all-day. Imports into external calendar apps are supported through file export. Continuous two-way OAuth synchronization with Google, Apple or Outlook is not connected. Calendar views do not grant stakeholder access. Regional defaults do not change stored currency/rate snapshots.

## Offline and low-connectivity support

A user action prepares a service-worker app-shell cache. Production cache versions are derived from the static build content, and Vercel worker/manifest responses request revalidation. Only known public app assets are cached; private API responses and third-party requests are not cached. Source preview uses the worker template; production receives the build-specific worker. Browser storage may still be cleared or evicted, so a separate backup matters.

The private day pack is an independent, self-contained HTML download containing selected schedules, tasks, necessary assigned contacts and venue instructions. It has no external asset dependencies and excludes finances, guest lists, identity references and personal preparation notes. Stakeholder filtering is not a security boundary. Offline activity/inspection edits can be exported as a JSON report. Import checks project/event scope, original revisions, allowed transitions, current readiness, dependencies and linked task approvals; the report applies atomically or is rejected for review. Completed activity records cannot be rewritten. This is manual reconciliation, not cloud synchronization.

Edits in the cached main app remain in the same browser storage when connection returns. No server outbox is labeled sent, and no automatic cross-device merge is claimed. A private whole-device backup download is available.

## Regional and multicultural support

Users can choose country/region, date/number locale, default time zone, custom vendor/attire categories and freeform traditions, family terminology and gift customs. Optional Nigerian, South Asian, civil/intimate and custom multi-day starters add editable celebrations without replacing existing events. Templates are examples, not cultural or legal requirements. Multiple ceremonies, manual multi-currency expense snapshots, traditional attire and regional registry guidance remain in their existing modules.

The planning interface remains English. The mini website also offers French headings and author-written translated text. Locale preferences do not constitute a fully translated application.

## Validation

All existing model suites and static builds pass. New tests cover inferred/manual connections, project/private search scope, change deduplication, quiet hours, cross-zone/DST conflicts, version retention, identity-upload guards, atomic/stale offline reports, safe embedded JSON and service-worker fallback/no-private-API caching. Browser checks cover dress-to-expense/order/outfit/registry connections and original editing, document upload/version restoration, consolidated activity/expiry reminders, quiet-hour muting, conflict rejection/free-slot acceptance, cached-shell readiness, cultural starters/custom vocabulary and mobile layouts.

The downloaded day pack was inspected for self-contained assets and financial exclusion. Its actual exported revisions reconciled against the downloaded QA project snapshot. Automatic external calendar synchronization, secure sharing, authenticated permissions and shared server synchronization remain backend work.

Technical references: [MDN: using service workers](https://developer.mozilla.org/en-US/docs/Web/API/Service_Worker_API/Using_Service_Workers), [MDN: Cache.addAll](https://developer.mozilla.org/en-US/docs/Web/API/Cache/addAll).
