# Amazon product photos

Amazon can return a CAPTCHA page to the public link reader. That page is not a product preview. The importer now rejects it and can use an optional Rainforest API product lookup instead.

## Activate the connection

1. Create a Rainforest API account at https://trajectdata.com/discover-rainforest-api/ and obtain its API key. Review the provider's terms and current allowance before enabling paid usage.
2. In Vercel, open the Cobridey project's Settings > Environment Variables. Add `RAINFOREST_API_KEY` for Production. This is server-only; never add it to frontend code or share it in chat.
3. Redeploy the production project.
4. While signed in, add https://www.amazon.com/dp/B09HR6MV21 to the registry or shopping list and verify its actual product photo.

No database migration is required. Until the key is configured, blocked Amazon pages cannot provide a photo. Existing product links remain usable. Approved Amazon Creators API access is a separate potential integration, not a prerequisite for this adapter.

The adapter requests only the ASIN and Amazon marketplace from a fixed provider endpoint. It validates the returned ASIN and Amazon-hosted HTTPS image, keeps credentials out of responses, coalesces simultaneous requests, and caches successful lookups for one hour per running server instance (up to 200 products). Cache entries are not a persistent global spending cap; monitor provider usage and configure its billing controls. Existing authenticated import limits still apply.

Provider documentation: https://docs.trajectdata.com/rainforestapi/product-data-api/parameters/product
