# Saving release verification

Automated checks: `node --test cloud-storage.test.cjs auth.test.cjs onboarding.test.cjs sign-out.test.cjs`.
These use isolated device contexts and an emulated revision-checked server. They do not substitute for authenticated production verification.

## Real-account acceptance test (phone and computer)

1. Sign into the same ordinary account on both devices. On the computer create a task called “Saving check”. Wait for “All changes saved”. Refresh the phone and confirm it appears.
2. Upload a small photo to Vision Studio and a supported small document. Wait for confirmation, refresh the other device and open both attachments.
3. On the computer disconnect the internet, edit the task and confirm an offline/waiting message. Reconnect and choose Retry saving if needed. Wait for confirmation, then refresh the phone.
4. Keep both devices open on the same version. Edit and save on the computer, then edit on the phone before refreshing it. The phone must show a conflict. Download its changes before choosing Load latest saved version. Confirm the computer’s saved edit was not overwritten.
5. Sign out, then sign in to a different account. Neither the first account’s task nor attachments may appear.
6. Record device/browser, time, step and exact error for any failure. Do not share passwords, login links or verification codes.

## Current storage limits

Uploads are embedded in the account workspace snapshot; a 19 MB client guard leaves room under the database's 20 MB JSON limit. Individual upload forms have smaller limits. Large media libraries require dedicated object storage before promising unrestricted uploads. A failed or oversized save remains pending, can be downloaded, and is never labelled saved. Conflicts require explicit recovery; no automatic merging is attempted.

Production acceptance: pending user execution on phone and computer.
