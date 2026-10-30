# Shared celebration issues

Team experience plan → Issues records operational follow-up with title, shared details, priority, Open/Investigating/Resolved status, optional affected service, accepted assignee and explicit cue-blocking choice. Authorized celebration readers can view current issues. Native planning writers can report or update them. New reports do not copy private source briefs or vendor details.

A blocker applies to its selected service, or all cues when Whole celebration is explicitly selected. While unresolved, it prevents a transition into Running. Clearing the blocker or resolving the issue releases it. A newly reported blocker does not halt already Running cues; their completion/skip can still be recorded. This is manual coordinator workflow, not emergency dispatch, physical equipment control, email or SMS delivery.

The start guard is a database trigger on canonical cue transitions. Both issue writes and cue writes take the wedding project lock, preserving a consistent order against concurrent changes. Revision checks protect the event, selected service and issue; exact request replay prevents duplicate reports after network interruption. Resolution requires a note and records a server timestamp. Reopening clears the current resolution timestamp while preserving earlier history.

Raw issue/history/write tables and the trigger function are not client-accessible. Issue boards recheck event membership and expiry. New assignments must have current celebration access. Readers do not receive edit controls or historical status lists. Writers can review recent status/blocking history, without exposing earlier edited note text in the history projection. Dialog refresh pauses in forms and sign-out clears it.

Activation: run supabase/experience-issues.sql after shared-experience.sql and experience-run-show.sql. Additive, rerunnable and preserves current experience/cue records.

Validation: native PGlite tests use actual shared experience/run-of-show functions, covering targeted and celebration-wide blockers, unrelated cues, in-progress completion, resolution notes, released blocks, atomic rejected starts, exact retries, stale reports, assignment, event readers, expired access, anonymous/direct table denial and audit history. Mobile UI tests cover reviewed blocker scope, network retry, required resolution, conflict retention, reader controls, layout and reset. Authentication checks verify logout cleanup. Live account/device tests remain deferred at the user's request. Verification sent no messages or production issue reports.
