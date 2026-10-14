# Stakeholders, communication and collaboration

Part III adds interactive local planning workflows to the existing wedding project model. Existing browser records migrate without overwriting their fields; migration is idempotent.

## Stakeholder relationships
Couple, partner, family, bridal party, planners, vendors, sponsors, guests, merchants and venues have profiles with contact notes, relationship, responsibilities, event assignments, access role, temporary-access end date, delegated-authority notes and unavailable dates. Commitment records support financial, sponsorship, in-kind and responsibility promises with deadlines and fulfilled status. They are separate from budget expenses and do not transfer or automatically count money. Task assignments can reference a stable stakeholder ID; profiles also recognize existing name-based assignments.

## Communication hub
Create direct, couple, family, bridal party, vendor, planner, event, task, order, budget and inquiry spaces. Context links refer to canonical event/task/purchase/expense records in the active project. Direct spaces require one other stakeholder. Private notes cannot include participants. Messages, announcements, inquiries and negotiations are local records; recorded authors are selected manually and are not identity-verified.

Messages support text, up to three image/PDF/text/audio files of 200 KB each, pinning, search, a local appreciation toggle, polls with one replaceable vote per person, and manually recorded acknowledgements. These acknowledgements are not real read receipts. Images and audio have inline previews; files can be downloaded.

Convert messages into tasks, decision proposals or expense drafts. Saving the draft preserves a source-message link. Decision proposals can create resulting tasks and purchases with reciprocal links. Nothing is sent or booked. Dated event conversations can export an all-day .ics calendar entry, which the user can import or share themselves.

## Roles and access plans
Templates and custom roles describe intended assigned-task, event, bridal-party, own-commitment, vendor, guest, full-finance, approval and collaborator-management scopes. Stakeholders can have draft, invitation-planned, active-plan or revoked status and an expiry date. The access preview includes grants only for active, unexpired plans. Vendor and family defaults exclude full financial visibility.

This is a design preview, not a security boundary. It does not create invitations, separate authenticated users, private server workspaces or enforced permissions. All browser data remains accessible to the device user. Server authentication, authorization, membership checks and access-scoped queries are required before actual collaboration.

## Decision and approval management
Proposals contain an owner, priority, deadline, event context, comparison options, quotes, details, supporting files, named approvers, votes, comments and local history. Each stakeholder has one replaceable option vote. The first recorded approval selects an option; subsequent approvals must match it. Approved status requires every requested approver to approve that selection. Proposal edits involving options, approvers, title, context, deadline, event or supporting evidence invalidate previous approvals. Reopening and requesting changes also clear approvals.

Approvals are explicitly self-recorded by the local user. The history is browser data, not immutable or independently verified. Real-time chat, live receipts, microphone recording, translation, external communication integrations, delivered reminders and collaborator-enforced approval flows remain planned. Audio-file attachments work now.

## Validation
`npm test` runs both scheduling and collaboration model tests. Browser checks cover stakeholder saving, role financial restrictions, commitments, conversations, pinning, polls, message conversion, two-approver gating, resulting-task synchronization, approval invalidation and reload persistence. Test interaction uses a separate loopback origin to preserve the user's localhost planning data.

## Connected collaboration samples
CollaborationSamples seeds the two fictional planning projects once, preserving existing real projects and records. Each sample project receives 11 conversation spaces and 34 authored message records, with pinned updates, announcements, a bridal styling poll, manual acknowledgment examples, fictional quote negotiation, a coordination brief, private notes and contextual links into tasks, shopping and budgets. No send, delivery, read receipt or verified identity is inferred.

The directory covers the bride, partner, parents/family, bridesmaids, planner, vendors, sponsor, guest, merchant and venue, plus a delegated logistics lead and a revoked former consultant. Responsibilities, event assignments, commitments, custom roles and temporary access dates depict intended scope. Sponsor access previews show own commitments; vendor/planner previews exclude full finances. These are planning records, not actual account permissions or a participant portal switcher.

Five additional proposals per sample project demonstrate a three-option floral comparison with partial approvals, unanimous shuttle approval, invitation wording changes, an overdue supplier-access issue, and a resolved accessory choice linked to a shopping record. Supporting files, votes, comments, histories and resulting-task links are included. The sample proposal opens automatically and access preview defaults to the planner. Edits persist; the seed marker prevents duplication. Tests check memberships, project/event/context scope, roles, polls, acknowledgments, approvals, preserved data and zero transmitted messages or payments.
