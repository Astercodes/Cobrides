# Shared run of show

Team experience plan → Run of show queues explicitly reviewed service cues in source order/time. Authorized celebration readers see current progress; native planning writers coordinate it. The sheet refreshes every 15 seconds while no form edits are pending. It pauses refresh during edits or writes, and sign-out closes the dialog and stops its timer.

Manual states: Pending → Ready → Running → Complete. Coordinators may Skip with a reason, Reopen finished cues with a reason, or Remove non-running cues with a reason. Removed cues can be requeued against their current service/event revisions. Parallel Running cues are supported. There is no automatic clock trigger, service completion, task completion, booking, payment, notification delivery or AV command.

Starting requires reviewed current source/event revisions and completed source readiness checks. Changed service or celebration details require Review; reviewing a Ready cue resets it to Pending. Finished historical snapshots are not rewritten by Review: reopen first. A running cue can record Complete/Skip even if the source was cancelled after it started, retaining the original reviewed snapshot and source-change flag. It cannot simply disappear mid-run.

Every action is explicitly confirmed, revision checked, exact-retry protected and stored in immutable cue history with server timestamps. Only safe shared title/category/order/time/date fields enter the reviewed snapshot. Private briefs, contact details, specifications and finances are not copied. Read-only viewers see active cues without edit controls or removed-cue lists. Event access and expiry are checked server-side for every read/write. Raw tables are inaccessible to client roles.

Activation: run supabase/experience-run-show.sql after shared-experience.sql. Additive and rerunnable; existing experience records and readiness statuses stay unchanged.

Validation: experience-run-show.sql.test.cjs uses native project/access/experience functions to test transitions, exact retries, readiness gates, event/source changes, re-review, historical timestamps, cancellation during a run, safe removal, role/expiry/anonymous restrictions, snapshots and history. Mobile UI tests cover queue retries, manual progress, reader access, changed-source action restrictions, conflicts, closure and reset. Authentication tests verify logout cleanup. Live account/device validation remains deferred at the user's request; verification created no production events, commands or messages.
