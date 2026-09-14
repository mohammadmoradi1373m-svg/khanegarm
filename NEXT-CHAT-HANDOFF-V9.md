# خانه‌گرم / owli.ir — V9 Handoff

نسخه V9 بعد از regression audit منتشر شده است.

## اصلاحات V9
- fix `submitReview()` برای Clean URL router: استفاده از `parseLocation()` به جای `parseHash()`.
- restore `runHomeSearch()` که در refactor router حذف شده بود.
- حذف تکرار `?id=` از URLهای `/product/:id`.
- هماهنگ‌سازی دسترسی `get_delivered_orders_count()` با استفاده anonymous صفحه اصلی.
- Production DB: status constraint `-1..3` برقرار شد.

## وضعیت تست
- JS syntax: PASS
- PHP syntax: PASS
- static regression scan: PASS
- router/review runtime mock: PASS
- Production DB permission checks: PASS
- Production status constraint: PASS
- Browser end-to-end واقعی روی دامنه: **نیازمند تست روی هاست واقعی است**

## فایل‌های مهم
- `index.html` — storefront + router + review fix
- `index.php` — proxy + clean-route serving
- `sitemap.xml` — clean static routes
- `DB-PERFORMANCE-INDEXES.sql` — indexes
- `DB-V8-STATUS-HARDENING.sql` — order status semantics + permissions
- `FINAL-REGRESSION-AUDIT-V9.md` — گزارش کامل regression audit

## اصل ادامه کار
قبل از هر تغییر جدید:
1. regression scan
2. تغییر کوچک و مشخص
3. syntax/static test
4. runtime test تا حد امکان
5. تست واقعی روی هاست برای موارد network-dependent
