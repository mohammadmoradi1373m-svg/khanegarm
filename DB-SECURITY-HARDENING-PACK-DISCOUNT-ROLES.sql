-- OWLI / خانه‌گرم
-- SECURITY HARDENING: restrict admin-only discount/pack policies to authenticated role.
-- This file is prepared for manual application in Supabase SQL Editor.
-- No database change has been applied by this file.

begin;

drop policy if exists product_discounts_admin_delete on public.product_discounts;
drop policy if exists product_discounts_admin_insert on public.product_discounts;
drop policy if exists product_discounts_admin_select on public.product_discounts;
drop policy if exists product_discounts_admin_update on public.product_discounts;

create policy product_discounts_admin_delete
on public.product_discounts
for delete
to authenticated
using ((auth.jwt() ->> 'email') = 'mohammadmoradi.1373m@gmail.com');

create policy product_discounts_admin_insert
on public.product_discounts
for insert
to authenticated
with check ((auth.jwt() ->> 'email') = 'mohammadmoradi.1373m@gmail.com');

create policy product_discounts_admin_select
on public.product_discounts
for select
to authenticated
using ((auth.jwt() ->> 'email') = 'mohammadmoradi.1373m@gmail.com');

create policy product_discounts_admin_update
on public.product_discounts
for update
to authenticated
using ((auth.jwt() ->> 'email') = 'mohammadmoradi.1373m@gmail.com')
with check ((auth.jwt() ->> 'email') = 'mohammadmoradi.1373m@gmail.com');

drop policy if exists packs_admin_select on public.packs;
create policy packs_admin_select
on public.packs
for select
to authenticated
using ((auth.jwt() ->> 'email') = 'mohammadmoradi.1373m@gmail.com');

drop policy if exists pack_items_admin_select on public.pack_items;
create policy pack_items_admin_select
on public.pack_items
for select
to authenticated
using ((auth.jwt() ->> 'email') = 'mohammadmoradi.1373m@gmail.com');

commit;
