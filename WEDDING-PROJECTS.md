# Wedding project backend

Apply `supabase/wedding-projects.sql` after collaboration.sql and accounts.sql. The migration is transactional and rerunnable. Existing account workspaces remain intact.

Wedding Projects offers Connect wedding team for existing personal projects; new projects connect after the personal save succeeds. The dialog manages shared metadata, invitations, membership, celebration access, archive/restore, and activity. Invitations can be shared through email, WhatsApp, messages, or a copied link. Accepting requires the invited verified email account. Planner ownership transfers require an explicit bride invitation.

Server permissions and row-level security control every shared read and mutation. Financial visibility is separately granted; vendor/guest celebrations require explicit assignments. Revision checks reject stale writes. Removing membership immediately blocks subsequent server access. Shared details refresh while the workspace is visible.

Only whitelisted project and celebration metadata is shared. Personal tasks, conversations, guest lists, journals, purchase records, and detailed financial ledgers are not automatically published. Shared responsibility/message records in collaborate.html retain their existing collaboration model. Connect those individual modules deliberately in later work.

Validation: wedding-projects.test.cjs covers client metadata selection, namespaces, imported permissions, and revoked access. wedding-projects.sql.test.cjs runs real migrations twice against PGlite when CB_PGLITE_PATH points to its runtime, checking row isolation, invitations, finances, event assignments, conflicts, archive/restore, and revocation. Production acceptance still requires two real accounts to test invite delivery/acceptance and cross-device updates.
