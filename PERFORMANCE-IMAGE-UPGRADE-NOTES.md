# Khanegarm Performance + Image Upgrade

این نسخه بر پایه ZIP اصلی GitHub ساخته شده و فقط اصلاحات Performance/تصاویر روی آن اعمال شده است.

## Frontend / تصاویر
- آپلود تصویر محصول: تبدیل به WebP قبل از Storage.
- تصویر اصلی: حداکثر 2500px و هدف حجم حدود 4.7MiB یا کمتر.
- thumbnail: حداکثر 480px برای کارت‌ها و thumbnailهای گالری.
- تصاویر جدید با Cache-Control یک‌ساله و نام یکتا ذخیره می‌شوند.
- برای تصاویر قدیمی JPG/PNG، thumbnail حدس‌زده نمی‌شود تا درخواست 404 اضافی ایجاد نشود؛ تصویر قدیمی مستقیم fallback می‌شود.
- صفحه محصول: تصویر اصلی برای Zoom نگه داشته می‌شود؛ Zoom کلیک/چرخ موس/drag/pinch تا 4x دارد.
- اگر مرورگر نتواند فرمت تصویر را decode/convert کند، فایل خام به‌صورت ناامن و بی‌قید upload نمی‌شود و پیام واضح نمایش داده می‌شود.
- Preview فایل‌های جدید در Admin، URLهای موقت خود را revoke می‌کند.

## Admin / Database
- Dashboard: چهار Query اصلی به‌صورت موازی اجرا می‌شوند و فقط ستون‌های لازم را می‌گیرند.
- لیست سفارش‌ها/محصولات/نظرات/وظایف/ارسال مطالب از `select('*')` به فیلدهای موردنیاز تغییر کرده‌اند.
- Categories: دریافت دسته‌بندی و شمارش محصولات موازی شده است.
- گزارش فروش فقط ستون‌های موردنیاز سفارش را می‌گیرد.
- هنگام ورود Admin، Dashboard/Orders دیگر بی‌دلیل Categories را fetch نمی‌کنند.

## Database indexes
این چهار Index روی Supabase Production اعمال شده‌اند:
- idx_orders_created_at_desc
- idx_reviews_created_at_desc
- idx_admin_todos_created_at_desc
- idx_guide_submissions_status_created_at_desc

## Proxy
Proxy هاست ایرانی (`api.owli.ir`) دست‌نخورده و معماری فعلی حفظ شده است. مسیر اصلی API و امنیت Proxy تغییر نکرده است.

## محدودیت تست
تست استاتیک HTML/JS/PHP انجام شده است. تست Network واقعی از محیط توسعه به دامنه عمومی به دلیل محدودیت DNS/شبکه این محیط قابل انجام نیست؛ بنابراین زمان واقعی پاسخ Proxy/Storage را ادعا نمی‌کنیم و باید پس از Deploy در Browser Network اندازه‌گیری شود.

## تصاویر قدیمی
این نسخه تصاویر قدیمی را خودکار overwrite نمی‌کند. محصولات جدید با pipeline جدید ذخیره می‌شوند. برای تبدیل تصاویر قدیمی می‌توان migration جداگانه و کنترل‌شده انجام داد.
