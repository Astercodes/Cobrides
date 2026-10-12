# Separate participant workflows

The bride workspace has no participant switcher or participant navigation. Public welcome.html directs each participant to a dedicated page. Platform administration lives separately at admin.html and is omitted from public onboarding.

Partner, planner, bridal party, family, vendor, merchant, guest and venue each have a dedicated onboarding form, navigation and manually maintained workflow records. Each stores data under a separate furbrides-participant-v1:<role> key. They do not read or write furbrides-v1, import bride records, or link to bride tools. Planner client engagements remain independent records in the planner workspace, without transferring wedding ownership.

These separate workflows are browser-local prototypes. They are not authenticated accounts or enforceable security boundaries. Invitation redemption, couple-approved record sharing, cross-account synchronization, professional teams, external messages, RSVP submission, order fulfillment, verification and moderation services require backend implementation. Manually recorded status changes do not perform these actions.
