# خانه‌گرم — V8 handoff

## This release
V8 is based on final-release-v7 and adds a real final order state:
- -1 لغو شده
- 0 در حال بسته‌بندی
- 1 تحویل داده‌شده به پست/باربری
- 2 در حال ارسال
- 3 تحویل داده‌شده

Production Supabase migration `final_order_status_delivery_stage` was applied and verified.

## Verified in production
- `orders_status_valid` now accepts -1..3.
- Valid transitions: 0→1→2→3; invalid backward/skip transitions rejected.
- `admin_set_order_status` accepts 0..3 and remains admin-email protected.
- `admin_bulk_set_order_status` accepts 0..3 and retains max 100/order validation.
- `get_delivered_orders_count()` now counts only status=3.
- Admin RPCs remain unavailable to anon.

## Still host-dependent
- Browser → api.owli.ir → PHP proxy → Supabase end-to-end.
- Production deployment of this V8 package.
- Real checkout/payment/fallback/upload/Turnstile tests.
- Leaked Password Protection remains intentionally deferred.
