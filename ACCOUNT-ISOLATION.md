# Account and delayed-response isolation

The shared authenticated request layer rejects results after logout, cross-tab logout or account replacement. REST/storage calls require a currently stored matching account session before sending. Account-context preferences use the same fence. Protected screens with an established identity also reject a response for another identity. Context is checked before and after configuration loading and response parsing, so older modules cannot accidentally consume late records merely because they lack their own post-request check.

Replacing an account invalidates pending work and resets private workspace caches. Same-account verified token rotation remains valid. Explicit account replacement preserves the current sign-in intent and pending invitation; sign-out still clears them. New-user onboarding refuses data carrying another account ID instead of relabelling it as the new account. Legacy workspaces without an account ID remain supported, and ordinary new accounts still start empty.

No database migration or provider credentials are needed. Existing database permissions remain authoritative. This does not undo a write already accepted by the server before logout, or revoke copies a user has already downloaded. It prevents the late response from updating the signed-out or replacement interface.

Tests cover delayed protected reads, mutation response fencing, cross-tab logout without a storage event, account replacement, stale stored sessions, pre-send checks, account-context preferences, token rotation, invitation preservation, onboarding isolation and existing email/password/cloud-save flows. Live real-account/multi-device checks remain deferred at the user's request.
