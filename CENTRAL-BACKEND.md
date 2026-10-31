# Central overview

Central now reads one permission-checked server overview of the current shared wedding. It projects task fields without descriptions, accessible celebrations and the native wedding date, per-event RSVP counts, per-currency canonical budget totals, payment deadlines, pending decision counts and open operational issue counts. It never returns guest names, contacts, dietary notes, invitation tokens, detailed incident notes or full financial journals.

RSVP counts use current event eligibility, retaining confirmed answers when only the reply link is revoked. Guest summaries require guest-management access; financial summaries/deadlines require finance access. Current task, decision and restricted-event visibility helpers apply. Expired access is denied. The overview is read-only and creates no records, notifications or emails.

The established charts remain. Personal tasks are deduplicated against their shared references; private events are merged with accessible canonical celebrations without retaining stale shared event projections. Shared budget totals come from the existing financial report, which owns settlements, payments, refunds and cross-module expense deduplication. Currencies are selectable and are never added together. Restricted sections show Private rather than financial/guest zeros. Shared-read failures show a retry state instead of silently substituting personal totals. Private-only weddings keep their existing local overview.

Refresh occurs on returning to Central, window focus, visibility restoration, every thirty seconds while Central is visible, or manually. User/project/scope keys and generation checks discard late responses. Sign-out clears cached totals and halts further overview refreshes. The visible countdown uses the authoritative wedding date.

Activation: run supabase/central-overview.sql after the installed planning, guest RSVP, decision, expense/budget and shared experience migrations. Additive and rerunnable; no wedding data is changed.

Validation: native SQL tests use actual project access, guest records, expense/budget reports and task visibility. They cover revoked-reply RSVPs, restricted celebrations, finance/guest denial, expired and unrelated accounts, anonymous denial and safe response fields. Mobile tests cover task deduplication, native dates, current RSVPs, chart structure, currency selection, interrupted reads, access changes, reset and overflow. Real phone/computer tests remain deferred by the user.
