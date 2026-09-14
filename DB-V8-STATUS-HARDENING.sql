-- خانه‌گرم: V8 final order-status semantics hardening
-- Statuses: -1 cancelled, 0 packing, 1 handed to carrier, 2 in transit, 3 delivered.
--
-- This migration intentionally does NOT contain the performance indexes.
-- Those are maintained separately in DB-PERFORMANCE-INDEXES.sql.

alter table public.orders
  drop constraint if exists orders_status_valid;

alter table public.orders
  add constraint orders_status_valid
  check (status = any (array[-1, 0, 1, 2, 3]));

create or replace function private.is_valid_order_status_transition(p_old integer, p_new integer)
returns boolean
language sql
immutable
security definer
set search_path = ''
as $$
  select case
    when p_old is null or p_new is null then false
    when p_old = -1 then p_new = -1
    when p_old = p_new then true
    when p_old = 0 and p_new = 1 then true
    when p_old = 1 and p_new = 2 then true
    when p_old = 2 and p_new = 3 then true
    else false
  end;
$$;

create or replace function public.admin_set_order_status(p_order_id uuid, p_status integer)
returns boolean
language plpgsql
security definer
set search_path = 'public', 'private', 'pg_temp'
as $$
declare
  v_old_status integer;
begin
  if (select auth.jwt() ->> 'email') <> 'mohammadmoradi.1373m@gmail.com' then
    raise exception 'NOT_AUTHORIZED';
  end if;
  if p_status not between 0 and 3 then
    raise exception 'INVALID_STATUS';
  end if;
  select status into v_old_status
  from public.orders
  where id = p_order_id
  for update;
  if not found then
    raise exception 'ORDER_NOT_FOUND';
  end if;
  if not private.is_valid_order_status_transition(v_old_status, p_status) then
    raise exception 'INVALID_STATUS_TRANSITION';
  end if;
  update public.orders set status = p_status where id = p_order_id;
  return true;
end;
$$;

create or replace function public.admin_bulk_set_order_status(p_order_ids uuid[], p_status integer)
returns integer
language plpgsql
security definer
set search_path = 'public', 'private', 'pg_temp'
as $$
declare
  v_count integer;
  v_invalid_count integer;
begin
  if (select auth.jwt() ->> 'email') <> 'mohammadmoradi.1373m@gmail.com' then raise exception 'NOT_AUTHORIZED'; end if;
  if p_status not between 0 and 3 then raise exception 'INVALID_STATUS'; end if;
  if p_order_ids is null or cardinality(p_order_ids) < 1 or cardinality(p_order_ids) > 100 then raise exception 'INVALID_ORDER_COUNT'; end if;
  select count(*) into v_invalid_count from public.orders o where o.id = any(p_order_ids) and not private.is_valid_order_status_transition(o.status, p_status);
  if v_invalid_count > 0 then raise exception 'INVALID_STATUS_TRANSITION'; end if;
  update public.orders set status = p_status where id = any(p_order_ids);
  get diagnostics v_count = row_count;
  if v_count <> cardinality(p_order_ids) then raise exception 'ORDER_NOT_FOUND'; end if;
  return v_count;
end;
$$;

create or replace function public.get_delivered_orders_count()
returns integer
language sql
security definer
set search_path = 'public'
as $$
  select count(*)::integer from public.orders where status = 3;
$$;

-- SECURITY DEFINER functions must not retain the default PUBLIC execute grant.
revoke execute on function private.is_valid_order_status_transition(integer, integer) from public, anon, authenticated;
revoke execute on function public.admin_set_order_status(uuid, integer) from public, anon;
revoke execute on function public.admin_bulk_set_order_status(uuid[], integer) from public, anon;
revoke execute on function public.get_delivered_orders_count() from public;

grant execute on function public.admin_set_order_status(uuid, integer) to authenticated;
grant execute on function public.admin_bulk_set_order_status(uuid[], integer) to authenticated;
grant execute on function public.get_delivered_orders_count() to anon, authenticated;
