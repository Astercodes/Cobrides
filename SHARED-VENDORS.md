# Shared vendor directory

Install supabase/shared-vendors.sql after chat-record-links.sql. Adds a shared directory independent of personal contacts/quotes/payments, plus conflict-safe edits, explicit viewers, archive and version history. No personal vendors are automatically published.

In Vendors & venues > Team directory, managers can create records. Share with team on a personal vendor opens a review containing only name, category, location, services, email, phone, portfolio and relationship stage. Quotes, files, private notes and payment data are never copied. A saved shared vendor is independent of its personal source. The account snapshot retains only its sharedVendorId reference.

Managers with planning-write permission manage records; the project owner and explicitly selected active accepted teammates can read them. Non-managers cannot read version history or edit. Table access is revoked; RPCs enforce current project permissions on every call. The separate /shared-vendors.html page works for invited collaborators without requiring a bridal workspace.

Saves serialize by project, use version numbers and compare account-owned idempotency payloads. Retrying an uncertain save returns the original result; changed retries and stale edits return PT409. Archive preserves history. Directory refreshes every twenty seconds while visible and idle. Linked conversations receive private update signals when a vendor changes.

Conversation > Take action > Link existing record > Vendors can reference a shared vendor. Reading the conversation does not grant vendor access; reading a vendor does not grant chat access. Personal vendor expenses and quotes retain their original private scope. Shared quotation, booking and financial workflows are subsequent phases.

Checks cover access, selected viewers, private-field rejection, retries/conflicts, record history, chat links and audience removal, archive, mobile reviewed sharing and existing account/chat flows. UI tests use mocked accounts and never send actual messages or email.
