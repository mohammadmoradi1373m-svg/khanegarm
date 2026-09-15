-- خانه‌گرم — V1 account/auth foundation
-- Login: Iranian mobile + password. Recovery: email.
-- SMS/OTP is intentionally NOT required by this migration.
-- Phone confirmation must remain disabled in Supabase Auth for this version.

alter table public.customers
  add column if not exists user_id uuid references auth.users(id) on delete set null,
  add column if not exists email text;

create unique index if not exists idx_customers_user_id_unique
  on public.customers(user_id)
  where user_id is not null;

create index if not exists idx_customers_email
  on public.customers(email)
  where email is not null;

alter table public.orders
  add column if not exists user_id uuid references auth.users(id) on delete set null;

create index if not exists idx_orders_user_id_created_at_desc
  on public.orders(user_id, created_at desc)
  where user_id is not null;

-- Backfill any account links that already exist.
update public.orders o
set user_id = c.user_id
from public.customers c
where c.user_id is not null
  and o.user_id is null
  and o.phone = c.phone;

-- Customers: users may see only their own row; admin keeps full read access.
drop policy if exists "customer read own profile" on public.customers;
create policy "customer read own profile"
  on public.customers for select
  to authenticated
  using ((select auth.uid()) = user_id);

-- Profile writes go through the SECURITY DEFINER RPC below so the browser cannot
-- change the account owner or attach another user's phone number.
drop policy if exists "customer insert own profile" on public.customers;
drop policy if exists "customer update own profile" on public.customers;

-- Orders: signed-in customers may see only their own account-linked orders.
drop policy if exists "customer read own orders" on public.orders;
create policy "customer read own orders"
  on public.orders for select
  to authenticated
  using ((select auth.uid()) = user_id);

-- Link/create the current customer's store profile from the authenticated session.
create or replace function public.sync_my_customer_profile(
  p_name text default null,
  p_email text default null,
  p_address text default null,
  p_postal_code text default null
)
returns public.customers
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_phone text := coalesce(auth.jwt() ->> 'phone', '');
  v_local_phone text;
  v_email text;
  v_name text;
  v_address text;
  v_postal text;
  v_row public.customers;
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;

  -- Supabase phone identities are normally stored as +98XXXXXXXXXX;
  -- the store keeps the existing 09XXXXXXXXX format.
  v_local_phone := regexp_replace(v_phone, '^\+98', '0');
  if v_local_phone !~ '^09[0-9]{9}$' then
    raise exception 'INVALID_AUTH_PHONE';
  end if;

  v_name := nullif(btrim(coalesce(p_name, '')), '');
  if v_name is not null and length(v_name) > 120 then raise exception 'INVALID_NAME'; end if;

  v_email := nullif(lower(btrim(coalesce(p_email, ''))), '');
  if v_email is not null and (length(v_email) > 254 or v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$') then
    raise exception 'INVALID_EMAIL';
  end if;

  v_address := nullif(btrim(coalesce(p_address, '')), '');
  if v_address is not null and length(v_address) > 1000 then raise exception 'INVALID_ADDRESS'; end if;

  v_postal := nullif(btrim(coalesce(p_postal_code, '')), '');
  if v_postal is not null and v_postal !~ '^[0-9]{10}$' then raise exception 'INVALID_POSTAL_CODE'; end if;

  insert into public.customers(phone, user_id, name, email, address, postal_code)
  values (v_local_phone, v_uid, coalesce(v_name, 'مشتری'), v_email, v_address, v_postal)
  on conflict (phone) do update
    set user_id = excluded.user_id,
        name = coalesce(excluded.name, public.customers.name),
        email = coalesce(excluded.email, public.customers.email),
        address = coalesce(excluded.address, public.customers.address),
        postal_code = coalesce(excluded.postal_code, public.customers.postal_code);

  -- If the customer already had guest orders under the same phone, attach them
  -- to the authenticated account so the order history is not lost.
  update public.orders
  set user_id = v_uid
  where user_id is null
    and phone = v_local_phone;

  select * into v_row from public.customers where user_id = v_uid limit 1;
  return v_row;
end;
$$;

revoke execute on function public.sync_my_customer_profile(text,text,text,text) from public, anon;
grant execute on function public.sync_my_customer_profile(text,text,text,text) to authenticated;

-- The order RPC remains callable by guests, but when a customer is signed in
-- it automatically links the new order to auth.uid().
create or replace function public.create_order_idempotent(
  p_name text,
  p_phone text,
  p_address text,
  p_shipping text,
  p_items jsonb,
  p_subtotal integer,
  p_payment_method text,
  p_payment_ref text,
  p_province text,
  p_city text,
  p_postal_code text,
  p_packaging_option text,
  p_packaging_fee integer,
  p_via_fallback boolean,
  p_idempotency_key text
)
returns json
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_existing_code text;
  v_result json;
  v_lock_key bigint;
  v_key text;
  v_uid uuid := auth.uid();
begin
  v_key := btrim(p_idempotency_key);
  if nullif(v_key, '') is null or length(v_key) > 120 then
    raise exception 'INVALID_IDEMPOTENCY_KEY';
  end if;

  v_lock_key := hashtextextended('order-idempotency:' || v_key, 0);
  perform pg_advisory_xact_lock(v_lock_key);

  select order_code into v_existing_code
  from private.order_idempotency
  where idempotency_key = v_key;

  if v_existing_code is not null then
    return json_build_object('order_code', v_existing_code, 'coupon', null, 'idempotent_replay', true);
  end if;

  v_result := public.create_order(
    p_name, p_phone, p_address, p_shipping, p_items, p_subtotal,
    p_payment_method, p_payment_ref, p_province, p_city, p_postal_code,
    p_packaging_option, p_packaging_fee, p_via_fallback
  );

  update public.orders
  set user_id = v_uid
  where order_code = v_result->>'order_code'
    and v_uid is not null;

  insert into private.order_idempotency(idempotency_key, order_code)
  values (v_key, v_result->>'order_code');

  if mod(hashtextextended(v_key, 0), 100) = 0 then
    delete from private.order_idempotency
    where created_at < now() - interval '30 days';
  end if;

  return v_result;
end;
$$;

revoke execute on function public.create_order_idempotent(text,text,text,text,jsonb,integer,text,text,text,text,text,text,integer,boolean,text) from public;
grant execute on function public.create_order_idempotent(text,text,text,text,jsonb,integer,text,text,text,text,text,text,integer,boolean,text) to anon, authenticated;

-- Account-related data should never be publicly enumerable.
revoke select on public.customers from anon;
