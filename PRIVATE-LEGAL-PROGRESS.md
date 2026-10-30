# Private marriage documentation progress

## Activation
Run `supabase/private-legal-progress.sql` after private account workspace record saving is installed. Ready-to-run copy: `C:/Users/ayeni/Downloads/cobridey-private-legal-progress.sql`.
The existing Marriage Documentation guided steps use the backend directly, with no new workspace or access gate.

## Scope
Owner-only action checkboxes, explicit step completion/reopening and optional-step applicability now have canonical progress, conflict protection, exact retries and history. This records the user's preparation progress; it does not verify legal eligibility, submit applications, issue certificates or certify that a jurisdiction's requirements have been met. Existing guidance and official-source links are unchanged.

## Data integrity
- Sources must be current owner account legalRecords in the correct personal/demo namespace and project. Scoped personal data takes precedence over legacy copies, including recategorized/moved records. Retired source versions are ignored.
- A step cannot be completed with unchecked actions. The existing guided authority-confirmation step additionally requires a secure source URL and a valid, nonfuture date checked by the user. Source URLs are not independently certified as authoritative by this feature.
- Source fields sent with a completion request must match the current account record. Changing the recorded source/date flags an earlier completion for review; it is not silently carried forward as current confirmation.
- Only Name & account updates and International documentation can be marked not applicable. Restoring a step does not invent completion. Unchecking an action reopens a completed step. Reopen step also preserves the completed actions for review.
- Checklist IDs/text and guide/category identity define a version. Changed checklists start a fresh review and show a notice; previous progress remains stored and returns if the previous definition is restored. Source notes/title/fee edits do not reset action progress. Legacy completion is imported once, only if its actions/confirmation are valid.
- Workspace locks, per-definition revisions and exact request IDs protect concurrent devices and ambiguous retries. History is immutable. Native progress, source records and financial records are separate: no fee payments, submissions or document receipts are inferred.

## Privacy
Tables have RLS and no raw client grants. RPCs require the owner account; team roles confer no access. Progress replies contain record/action IDs and flags, not notes, application references, witness details, fees or document contents. Existing legal notes remain in private account record storage. No files, identity scans or confidential agreements are copied into these tables. No messages, shared events or public activity are created. Logout clears the private progress cache.

## Validation
`private-legal-progress.sql.test.cjs`: rerun, legacy import, action validation, complete/reopen/undo, optional-step restrictions, exact retries, conflicts, source changes/future verification dates, definition changes/restoration, namespace/demo/account separation, history and raw/anonymous denial.
`private-legal-progress.ui.test.cjs`: actual guided-step rendering, old handler interception, blocked incomplete steps, complete/reopen, ambiguous retry, optional-step restore and private field exclusion.
Auth/session and spiritual-progress regressions protect existing owner workspaces. Portal preview includes Marriage Documentation. Real-account/multi-device testing remain deferred at the user's request.

Deadline reminders and fee-to-ledger integrations are separate later work; this migration does not change them.
