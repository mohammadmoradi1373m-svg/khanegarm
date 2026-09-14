# Khanegarm Performance Final

## Included
- Product image pipeline: WebP main image + thumbnail, lazy loading, async decoding, product image zoom.
- Legacy JPG/PNG images are not assumed to have sibling thumbnails; they fall back to the original URL.
- Admin dashboard/list queries are reduced to required columns and independent reads are parallelized.
- Database performance indexes for common admin list ordering/filtering are applied in Supabase migration `20260914085407_add_performance_indexes_for_admin_lists`.
- Iranian-host reverse proxy remains the active architecture. The proxy now streams upstream responses instead of buffering the full response in PHP memory before sending it to the browser.
- Proxy API responses are `no-store`; successful public Storage assets are cached for 7 days with immutable caching.
- Upload previews revoke temporary object URLs.

## Validation
- HTML parse: PASS
- Duplicate HTML IDs: 0
- Canonical tags: 1
- Robots tags: 1
- JavaScript syntax blocks: PASS
- PHP syntax: PASS
- ZIP integrity: PASS
- Production table/RLS/index checks performed against Supabase.

## Important runtime test
A real browser/network timing test from the user's Iranian host was not available in this environment. After deployment, verify the browser Network panel for `api.owli.ir` and Storage image requests, especially TTFB and transferred size.


## Final validation pass — 2026-09-14
- PHP syntax: PASS.
- Executable JavaScript syntax: PASS (4 executable inline blocks; 2 JSON-LD blocks validated separately).
- HTML structure: PASS; 0 duplicate IDs, 1 canonical, 1 robots meta, 2 valid JSON-LD blocks.
- Proxy negative-path checks: PASS for foreign Origin (403), unsupported method TRACE (405), and CORS preflight (204).
- Local positive upstream request could not be exercised because this sandbox PHP build has no cURL extension (`curl_init` unavailable); this is an environment limitation, not a production test result.
- Fixed during this pass: Storage-cache detection is now explicitly derived from the fixed `/storage/v1/object/public/` upstream path before streaming/caching logic.
- Production DB performance indexes were re-verified present in Supabase. RLS was re-verified enabled on the audited public tables. `create_order` and `create_order_idempotent` were re-verified as `SECURITY DEFINER`.
- Real browser/network timing, image download timing through the Iranian proxy, and live Turnstile positive/negative verification still require execution on the production host/browser.
