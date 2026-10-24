# Planning email setup

The sending key is already installed in Supabase Vault. Daily planning emails are opt-in.

## Activate delivery and bounce updates

1. In Resend, open Webhooks and add https://www.cobridey.com/api/resend-webhook.
2. Subscribe to email.delivered, email.bounced, email.complained, email.failed, email.delivery_delayed and email.suppressed.
3. Copy the generated signing secret (starts with whsec_).
4. Add it to Vercel production environment variables as RESEND_WEBHOOK_SECRET.
5. Add the same value to Supabase Vault as cobridey_resend_webhook_secret.
6. Redeploy Vercel. Never put the signing secret into chat, browser code or Git.
7. Replay a delivery event from Resend to check the callback. The earlier connection test has no planning job and will be acknowledged without changing account preferences.

Migration supabase/planning-delivery.sql installs private event processing and reconciliation. The endpoint returns 503 until its signing secret is configured. Recipients still receive daily summaries while delivery callbacks are awaiting activation.

Account email templates are stored in supabase/email-templates. Their brand tagline is Your Bridal Journey Companion.
