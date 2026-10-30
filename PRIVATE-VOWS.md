# Private vow autosave

Spiritual Preparation → Vows now uses owner-only canonical draft content with automatic saving after a short typing pause or field change. Existing account draft text initializes each native record once. Subsequent stale workspace snapshots cannot overwrite canonical content. Saved prose can be clicked or keyboard-activated to resume editing; the existing Create new draft workflow remains.

Writes require the owner's active, saved wedding and vow record. Personal and demo namespaces stay separate. Planner, partner and other project roles receive no access. No notifications, public activity or website publishing are added. Direct table access and the source helper are revoked from clients. Account deletion cascades native draft/history/write rows; sign-out clears controller text and timers.

Each changed text receives a revision and private history snapshot. Exact request IDs safely retry interrupted writes. New typing while a write is pending queues behind that exact write. A stale expected revision blocks overwriting, retains the editor's words, and offers an explicit confirmed reopen after the owner copies anything to keep. Leaving with unconfirmed text triggers a browser warning. Text is mirrored to the private workspace only after native save acknowledgement.

Activation: run supabase/private-vows.sql after existing account record storage. Rerunnable. Maximum 100,000 characters per draft. Existing retained history has no public/team read endpoint; a restore browser can be added later. No real user records or emails were used by tests.

Validation: private-vows.sql.test.cjs (ownership, namespace, retry, changed retry, stale revision, stale workspace, history, archive, anon and table grants), private-vows.ui.test.cjs (mobile hydration, exact retry, newer typing, conflict preservation/reopen and reset), auth-session.test.cjs (logout cleanup). Live cross-device checks remain deferred at the user's request.
