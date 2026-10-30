# Experience preparation task links

Team experience plan → Preparation task links a canonical shared planning task or creates one after explicit review. New tasks use only the title, instructions, accepted assignee and due date entered in the connector. Source experience notes, specifications and supplier text are never copied automatically. Linking existing tasks does not change their assignments, prerequisites, subtasks, approval requirements or completion.

Native planning write access and access to the celebration are required to manage links. Newly created assignments require an accepted collaborator who can access that celebration. Tasks retain the shared task board's own visibility and assignment permissions independently of the experience record; the confirmation explains this sharing boundary. Revoking celebration access does not automatically delete or reassign a previously created planning task.

The connector projects canonical current task completion. Completing a task does not mark an experience Ready or Complete. Unlinking retains the task. Updates check event, source item, link and selected task revisions. Exact request replay prevents duplicate task creation after interrupted connections. Native task creation and link/history writes commit atomically. Raw link/history/write tables are not granted to clients. Sign-out clears connection forms.

Activation: run supabase/experience-task-links.sql after shared-experience.sql, shared-planning.sql and task-board.sql. Additive, rerunnable and preserves existing tasks and experience records.

Validation: native PGlite tests use real project/access/task-board functions to verify reviewed creation, accepted event assignments, privacy, exact retries, no duplicate/orphan creation on conflicts, live completion, source readiness preservation, unlink, cross-wedding refusal, expired/read-only/anonymous denial and history. Mobile UI tests cover assignment review, exact network retry, unlink, conflict retention, closure and reset. Authentication cleanup tests run too. Live account/device checks remain deferred at the user's request. No production tasks or messages were created by verification.
