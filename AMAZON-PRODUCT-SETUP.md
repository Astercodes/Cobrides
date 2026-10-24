# Amazon product photos - free retrieval

No API key, affiliate tag, paid provider or database migration is required by the active importer.

The importer first reads the public retailer page. For Amazon.com product links that return a CAPTCHA or omit their image, it checks BigBangPrice's publicly accessible exact-ASIN product page. It requires an exact canonical URL, the same ASIN in the document title, structured product metadata and an Amazon-hosted HTTPS image. The original Amazon purchase link is preserved. It never substitutes search-result images or another product.

The public fallback supports Amazon.com only; another marketplace's product is not silently substituted. Unindexed or unavailable products retain their link without a fabricated image. This is best-effort public-page coverage, not an unlimited or guaranteed catalog API. Successful results are cached for one hour per server instance; misses for one minute. Concurrent requests for the same product share one lookup. The cache is bounded to 200 entries.

The fallback fetches only a fixed host and ASIN-only path, rejects redirects, applies a 12-second timeout and 1 MB response ceiling, and remains behind the existing authenticated import guard. It does not bypass CAPTCHA or sign in to Amazon. The dormant Rainforest helper is not called by the importer, even if a Rainforest key is present.

Verified live before deployment with B09HR6MV21 and B00FLYWNYQ. Both returned matching product metadata and Amazon image URLs that responded with HTTP 200 image/jpeg. The full importer also returned HTTP 200 for the user's original B09HR6MV21 link with its tracking parameters preserved.

Existing registry and shopping items without product images are already repaired automatically when those pages load. Reload the page after deployment to clear a previous in-memory failed lookup.
