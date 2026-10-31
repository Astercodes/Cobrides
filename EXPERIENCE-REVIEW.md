# Celebration review and archive

Team experience plan → Experience Archive → Celebration review. Native planning writers prepare a shared summary, highlights, lessons and follow-up. Only the current wedding owner can Finalize or Reopen. Reopening requires a reason; finalized notes cannot be edited directly. Ordinary celebration readers can view the review but cannot edit it.

The saved snapshot contains aggregate experience readiness, cue and issue totals only. No guest identities, dietary text, contracts, private source briefs, financial totals or payment data are joined into snapshots. Notes are explicitly entered and confirmed for the celebration team. This is a coordination review, not a public vendor review or guest survey. It does not archive the wedding project, finish tasks, settle expenses or change event/cue readiness.

Current source revisions are hashed from native experience, cue, issue and event revisions. A stale review is rejected rather than silently capture different totals. Counts and their revision hash are read in one SQL statement. Source changes after finalization flag the review but preserve its recorded snapshot. Saving a revised draft explicitly captures fresh totals. Running cues and unresolved blocking issues prevent finalization; nonblocking follow-up can remain in the next-steps notes.

Each mutation is exact-retry and review-revision protected, commits an immutable version snapshot and records server timestamps. Owner reopening preserves prior finalized history. The client shows recent saved-version metadata; raw snapshots, writes and source helpers are not exposed to client roles. Reads enforce current celebration access and expiration. Sign-out closes draft forms.

Activation: run supabase/experience-review.sql after shared-experience.sql, experience-run-show.sql and experience-issues.sql. Additive and rerunnable; existing plans and histories remain intact.

Validation: native PGlite tests cover planner drafts, owner-only finalization/reopening, exact retry, stale source snapshots, running/blocking guards, immutable finalized notes/totals, source-change flags, reopening, history and reader/anonymous/internal table denial. Mobile UI tests cover review drafts, exact retry, owner controls, reopening reason, stale-note retention, layout and reset. Authentication tests verify logout cleanup. Live account/device tests remain deferred at the user's request. No production reviews or external messages were created by verification.
