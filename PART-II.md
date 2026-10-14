# Part II — Wedding planning and project management

## Data model and migration

`planning-core.js` migrates the existing `furbrides-v1` browser record in place. Existing inspiration, purchases, guests, contacts, expenses and task completion are retained. A first wedding project inherits the previous profile date and budget; existing tasks and expenses are assigned to that project. Project switching does not erase account-level inspirations or identity.

Projects own phases, budgets, dates, candidate dates and engagement dates. Celebrations, tasks and register items have `projectId` relationships. Guests, contacts, purchases and expenses use `eventIds` to reference multiple celebrations. Event screens read those canonical records rather than making copies. Shared directories are account-wide; the expense view is scoped to the active project.

## 04 — Central and project management

Central shows completion, overdue work, open register items, remaining budget, reminders, upcoming celebrations, phase progress and recent local activity. Wedding projects can start blank or from classic and Nigerian templates. Project phases and task workstreams are customizable. Task progress can be grouped by workstream, owner, celebration or deadline window.

The register supports decisions, issues, approvals and change requests with priorities, deadlines, owners and outcome notes. Changes are recorded with the current profile name and local timestamp. This is a personal activity history, not independently authenticated stakeholder activity or immutable audit evidence.

## 05 — Timeline and projection engine

- Countdown widgets show days, hours and minutes and refresh while the page is open. Times use the device's local timezone; date-only countdowns target the start of the date.
- Confirmed, tentative and projected dates remain distinct. Candidate dates have no probabilities.
- Scenario previews do not overwrite saved dates. Relative wedding tasks and relative celebrations follow the candidate date. Manually scheduled tasks and celebrations remain fixed.
- Template celebration dates use offsets from the wedding date. Custom celebrations can use a manual date or a signed offset. Event-relative task deadlines follow the applicable celebration.
- Relative tasks work backward by `daysBefore`. Dependencies push deadlines forward as needed; recorded vendor-unavailable deadline dates are skipped for relative tasks and flagged for manual tasks. Availability constraints apply to the deadline, not every day of a multi-day task. Date conflicts are surfaced when dependencies or availability push work beyond its anchor date.
- The readiness chain is the longest remaining dependency chain by estimated calendar-day duration. It is a simplified critical-chain aid without resource leveling, working-day calendars, network slack analysis or live vendor calendars.
- Engagement anniversary countdowns and SVG countdown-card downloads are supported. February 29 anniversaries use March 1 in a non-leap year.

## 06 — Tasks and local workflows

Tasks include type, custom workstream, phase, celebration, owner, priority, status, deadline, duration, dependencies, approval record, approver, recurrence, handoff notes and subtasks. The dependency graph rejects cycles. Unfinished prerequisites, unfinished subtasks and pending or rejected approvals prevent completion. Completed dependent tasks must be reopened before their prerequisites can be reopened.

Completion can generate the next recurring occurrence, with renewed approval requirements and reset subtasks. A source occurrence is generated at most once, even if reopened. Tasks support local discussion notes and up to three PNG/JPEG/WebP/GIF/PDF/text attachments, each at most 200 KB.

Reminder windows surface upcoming and overdue tasks, payment deadlines, register responses, pending approvals, open event-linked purchases, scheduling conflicts, event budget overruns and vendor overlaps. Configurable local rules create one follow-up task per source record:

- Confirmed event → prepare its run sheet, scheduled seven days before the event.
- Paid expense → file its receipt, due the next day.
- Purchased item → check delivery or collection, due the next day.

Rules run on data saves in this browser. Enabling a rule also processes existing matching records. No background server, email, push notification, external booking or payment webhook is connected.

## 07 — Multi-ceremony celebrations

The Nigerian template creates introduction, traditional engagement, church wedding, reception and thanksgiving spaces. Additional types include civil ceremony, destination celebration, after-party, shower, fitting and payment deadline.

Each celebration has its own date, time, booking status, budget, venue, owner, dress code, menu, seating notes, invitation notes, running order, logistics, availability notes and checklist. Same-day shared-vendor overlaps are flagged; unspecified times are treated conservatively as potential overlaps.

A shared expense is counted once in its owning project. Its record value is split equally among its linked events for event-level totals. Unlinked expenses remain in the project total without appearing in an event total. Split weighting and partial-payment accounting are not implemented. Guest attendance and purchase status updates are reflected wherever their canonical records appear.

Invitation notes, menus and seating are editable planning records, not invitation delivery, interactive seating-chart or catering integrations.

## Collaboration boundary

Role-based views for partners, planners, family and vendors, verified approvals, shared discussions, durable storage and notification delivery require authenticated backend work. The interface identifies this boundary; no assignment or local note is sent to another person.

## Verification

`npm test` covers migration preservation/idempotency, leap/year date arithmetic, reverse schedules, dependency date conflicts, scenario isolation, event anchors, cycles, blockers, critical-chain durations, shared expense allocation, vendor overlap/unavailability and duplicate-safe workflow triggers. Browser checks cover project templates, approval blocking, prerequisite completion, subtasks, notes, recurrence, shared event expense views and event-confirmation follow-ups.

## Simulated real-use planning journey
PlanningSamples seeds two separate labeled fictional projects once per browser. Existing projects, tasks, profile fields, inspiration links and purchases are preserved. The new Lagos sample becomes active so the planning sections are populated immediately; the project selector still exposes existing projects.

Lagos: six ceremonies, 37 tasks (10 completed), four planning phases, recurring check-ins, approval gates, event-relative deadlines, dependencies, milestones, subtask checklists, local discussion and a sample venue brief attachment. Event pages include dress codes, menus, seating notes, programs, invitations, logistics, venue notes, guests, vendor contacts, shopping requirements and estimated expenses. Shared expense/event references demonstrate allocation without duplicate project spend. Three fictional decisions/issues and six historical planning activities show progress and unresolved work.

Seaside: a separate projected celebration, candidate dates, six exploratory tasks, guest travel-interest records, local coordinator/venue records and budget estimates. Future-date scenarios shift relative dates while keeping manually scheduled preparation deadlines unchanged. Initial sample record creation does not flood the unified notification feed; subsequent edits are tracked normally. No payment, purchase order, booking API call, sent message, invitation or delivered reminder is created. Financial estimates and recorded service selections are explicitly simulated. The sample version marker prevents duplicate re-seeding and preserves edits across reloads.
