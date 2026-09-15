-- خانه‌گرم — V2 username/password account flow
-- Login: username + password. Recovery: email only.
-- Phone is stored in public.customers and is NOT used by Supabase Auth.
-- Email confirmation should be disabled in Supabase Auth for this flow.

alter table public.customers
  add column if not exists username text;

create unique index if not exists idx_customers_username_lower_unique
  on public.customers (lower(username))
  where username is not null;

create index if not exists idx_customers_username_lower
  on public.customers (lower(username));

-- New account/profile sync. The phone belongs to the store profile, while
-- Supabase Auth identity is the recovery email + password.
create or replace function public.sync_my_customer_profile_v2(
  p_username text default null,
  p_phone text default null,
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
  v_username text := lower(nullif(btrim(coalesce(p_username, '')), ''));
  v_phone text := regexp_replace(btrim(coalesce(p_phone, '')), '[^0-9]', '', 'g');
  v_email text := nullif(lower(btrim(coalesce(p_email, ''))), '');
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
  v_address text := nullif(btrim(coalesce(p_address, '')), '');
  v_postal text := nullif(btrim(coalesce(p_postal_code, '')), '');
  v_existing public.customers;
  v_row public.customers;
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if v_username is null or v_username !~ '^[a-z0-9_]{3,32}$' then raise exception 'INVALID_USERNAME'; end if;
  if v_phone !~ '^09[0-9]{9}$' then raise exception 'INVALID_PHONE'; end if;
  if v_email is null or length(v_email) > 254 or v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'INVALID_EMAIL'; end if;
  if v_name is not null and length(v_name) > 120 then raise exception 'INVALID_NAME'; end if;
  if v_address is not null and length(v_address) > 1000 then raise exception 'INVALID_ADDRESS'; end if;
  if v_postal is not null and v_postal !~ '^[0-9]{10}$' then raise exception 'INVALID_POSTAL_CODE'; end if;

  select * into v_existing from public.customers where phone = v_phone limit 1;
  if v_existing.user_id is not null and v_existing.user_id <> v_uid then
    raise exception 'PHONE_ALREADY_LINKED';
  end if;

  if exists (
    select 1 from public.customers c
    where lower(c.username) = v_username
      and (c.user_id is null or c.user_id <> v_uid)
  ) then
    raise exception 'USERNAME_TAKEN';
  end if;

  insert into public.customers(phone, user_id, username, name, email, address, postal_code)
  values (v_phone, v_uid, v_username, coalesce(v_name, 'مشتری'), v_email, v_address, v_postal)
  on conflict (phone) do update
    set user_id = excluded.user_id,
        username = excluded.username,
        name = coalesce(excluded.name, public.customers.name),
        email = coalesce(excluded.email, public.customers.email),
        address = coalesce(excluded.address, public.customers.address),
        postal_code = coalesce(excluded.postal_code, public.customers.postal_code);

  update public.orders
  set user_id = v_uid
  where user_id is null
    and phone = v_phone;

  select * into v_row from public.customers where user_id = v_uid limit 1;
  return v_row;
exception
  when unique_violation then
    raise exception 'USERNAME_TAKEN';
end;
$$;

revoke all on function public.sync_my_customer_profile_v2(text,text,text,text,text,text) from public, anon;
grant execute on function public.sync_my_customer_profile_v2(text,text,text,text,text,text) to authenticated;

-- Resolve a username to the recovery email used by Supabase Auth.
-- This is intentionally limited to the exact username supplied by the user;
-- the client still performs the actual password verification through Auth.
create or replace function public.resolve_username_login_email(p_username text)
returns text
language sql
security definer
set search_path = public, pg_temp
as $$
  select c.email
  from public.customers c
  where lower(c.username) = lower(btrim(coalesce(p_username, '')))
    and c.email is not null
  limit 1;
$$;

revoke all on function public.resolve_username_login_email(text) from public;
grant execute on function public.resolve_username_login_email(text) to anon, authenticated;

-- Existing customers that have not yet migrated can still keep their old
-- profile row. New accounts use the V2 function above.
