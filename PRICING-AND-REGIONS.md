# CoBrides pricing and regional preferences

Free: Vision Studio, Planning & Tasks, Timeline & Countdowns, and Guest List.

Paid plan totals in NGN: one month 6,000; three months 15,000; six months 27,000; twelve months 50,000.

This release publishes the pricing presentation. Paid checkout, subscription activation, and server-enforced entitlements are not enabled. Plan links lead into the workspace and do not charge or grant a subscription. Existing planning records remain accessible. Billing integration must verify provider webhooks and persist entitlements against authenticated users before enforcing the four-feature free tier.

Country and display currency are independent global preferences, available in the header on every HTML entry point and retained between pages and tabs. The preference does not change wedding jurisdiction or recorded financial amounts. Financial displays use the existing FinanceCore formatter with a display-only currency conversion; forms, stored amounts, project currencies, entered historical rates and financial report amounts remain original.

Daily rates are fetched directly from ExchangeRate-API's public endpoint and cached for 24 hours. Cached snapshots older than 48 hours, future-dated snapshots, and missing currencies cause the original currency to be shown. Converted amounts are marked approximately; provider attribution is shown in the footer and regional settings. No private wedding information is sent in rate requests.

Source: https://www.exchangerate-api.com/docs/free
