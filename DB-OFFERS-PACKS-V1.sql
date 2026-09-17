create or replace function public.create_order(
  p_name text, p_phone text, p_address text, p_shipping text, p_items jsonb, p_subtotal integer,
  p_payment_method text default 'cod', p_payment_ref text default null, p_province text default null,
  p_city text default null, p_postal_code text default null, p_packaging_option text default 'postpay',
  p_packaging_fee integer default 0, p_via_fallback boolean default false
) returns json language plpgsql security definer set search_path=public,private,pg_temp as $$
declare
  v_code text; v_elem jsonb; v_agg record; v_stock int; v_price int; v_pname text; v_pcode text;
  v_real_subtotal bigint:=0; v_real_packaging_fee int:=0; v_norm_packaging text; v_built_items jsonb:='[]'::jsonb;
  v_attempt int:=0; v_total_qty int:=0; v_phone_key text; v_window_start timestamptz; v_order_count int; v_phone_limit int;
  v_headers json; v_ip text; v_ip_key text; v_ip_window_start timestamptz; v_ip_order_count int;
  v_type text; v_pid text; v_qty int; v_unit_price int; v_base bigint; v_pack jsonb; v_pack_items jsonb; v_pack_id uuid;
  v_requirements jsonb:='{}'::jsonb; v_req_qty int; v_discount record;
begin
  if nullif(btrim(p_name),'') is null or length(btrim(p_name))>120 then raise exception 'INVALID_NAME'; end if;
  if p_phone is null or p_phone !~ '^09[0-9]{9}$' then raise exception 'INVALID_PHONE'; end if;
  if nullif(btrim(p_address),'') is null or length(btrim(p_address))>1000 then raise exception 'INVALID_ADDRESS'; end if;
  if nullif(btrim(p_shipping),'') is null or length(btrim(p_shipping))>80 then raise exception 'INVALID_SHIPPING'; end if;
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)<1 or jsonb_array_length(p_items)>50 then raise exception 'INVALID_ITEMS'; end if;
  if p_payment_method not in ('cod','card') then raise exception 'INVALID_PAYMENT_METHOD'; end if;
  if p_packaging_option not in ('postpay','prepaid') then raise exception 'INVALID_PACKAGING_OPTION'; end if;
  if p_postal_code is not null and length(btrim(p_postal_code))>32 then raise exception 'INVALID_POSTAL_CODE'; end if;
  if p_payment_ref is not null and length(btrim(p_payment_ref))>120 then raise exception 'INVALID_PAYMENT_REF'; end if;
  if p_province is not null and length(btrim(p_province))>100 then raise exception 'INVALID_PROVINCE'; end if;
  if p_city is not null and length(btrim(p_city))>100 then raise exception 'INVALID_CITY'; end if;

  v_phone_key:=md5(lower(btrim(p_phone))); v_phone_limit:=case when p_via_fallback then 1 else 5 end;
  insert into private.order_rate_limits(phone_key,window_start,order_count) values(v_phone_key,now(),1)
  on conflict(phone_key) do update set order_count=case when now()-private.order_rate_limits.window_start>=interval '1 hour' then 1 else private.order_rate_limits.order_count+1 end,
  window_start=case when now()-private.order_rate_limits.window_start>=interval '1 hour' then now() else private.order_rate_limits.window_start end
  returning window_start,order_count into v_window_start,v_order_count;
  if v_order_count>v_phone_limit then if p_via_fallback then raise exception 'FALLBACK_ORDER_RATE_LIMITED'; else raise exception 'ORDER_RATE_LIMITED'; end if; end if;

  v_headers:=nullif(current_setting('request.headers',true),'')::json;
  v_ip:=coalesce(nullif(btrim(v_headers->>'cf-connecting-ip'),''),nullif(btrim(split_part(coalesce(v_headers->>'x-forwarded-for',''),',',1)),''));
  if v_ip is not null then
    v_ip_key:=md5(v_ip);
    insert into private.order_ip_rate_limits(ip_hash,window_start,order_count) values(v_ip_key,now(),1)
    on conflict(ip_hash) do update set order_count=case when now()-private.order_ip_rate_limits.window_start>=interval '1 hour' then 1 else private.order_ip_rate_limits.order_count+1 end,
    window_start=case when now()-private.order_ip_rate_limits.window_start>=interval '1 hour' then now() else private.order_ip_rate_limits.window_start end
    returning window_start,order_count into v_ip_window_start,v_ip_order_count;
    if v_ip_order_count>20 then raise exception 'ORDER_IP_RATE_LIMITED'; end if;
  end if;

  if p_packaging_option='prepaid' then v_norm_packaging:='prepaid'; v_real_packaging_fee:=300000; else v_norm_packaging:='postpay'; v_real_packaging_fee:=0; end if;

  for v_elem in select value from jsonb_array_elements(p_items) loop
    v_type:=coalesce(v_elem->>'type','product'); v_pid:=nullif(btrim(v_elem->>'id'),''); v_qty:=coalesce((v_elem->>'qty')::int,0);
    if v_pid is null or length(v_pid)>120 or v_qty<1 or v_qty>100 then raise exception 'INVALID_QTY: %',v_pid; end if;
    if v_type='pack' then
      begin v_pack_id:=v_pid::uuid; exception when others then raise exception 'INVALID_PACK: %',v_pid; end;
      select pk.id,pk.name,pk.pricing_type,pk.discount_value into v_pack from packs pk where pk.id=v_pack_id and pk.active and (pk.starts_at is null or pk.starts_at<=now()) and (pk.ends_at is null or pk.ends_at>now());
      if v_pack.id is null then raise exception 'PACK_NOT_FOUND: %',v_pid; end if;
      v_base:=0; v_pack_items:='[]'::jsonb;
      for v_agg in select pi.product_id,pi.quantity,p.stock,p.price,p.name,p.code from pack_items pi join products p on p.id=pi.product_id where pi.pack_id=v_pack_id order by p.name for update of p loop
        if v_agg.quantity<1 or v_agg.stock<0 or v_agg.price<0 then raise exception 'INVALID_PACK_ITEM'; end if;
        v_req_qty:=coalesce((v_requirements->>v_agg.product_id)::int,0)+(v_agg.quantity*v_qty); v_requirements:=jsonb_set(v_requirements,array[v_agg.product_id],to_jsonb(v_req_qty),true);
        v_total_qty:=v_total_qty+(v_agg.quantity*v_qty); if v_total_qty>100 then raise exception 'INVALID_ITEMS'; end if;
        v_base:=v_base+(v_agg.price::bigint*v_agg.quantity);
        v_pack_items:=v_pack_items||jsonb_build_object('product_id',v_agg.product_id,'code',v_agg.code,'name',v_agg.name,'quantity',v_agg.quantity,'unit_price',v_agg.price);
      end loop;
      if jsonb_array_length(v_pack_items)<2 or jsonb_array_length(v_pack_items)>10 then raise exception 'PACK_INVALID_ITEM_COUNT'; end if;
      if v_pack.pricing_type='percent' then v_unit_price:=greatest(0,round(v_base*(100-v_pack.discount_value)/100.0))::int; else if v_pack.discount_value>v_base then raise exception 'PACK_PRICE_INVALID'; end if; v_unit_price:=greatest(0,v_base-v_pack.discount_value)::int; end if;
      v_real_subtotal:=v_real_subtotal+(v_unit_price::bigint*v_qty);
      v_built_items:=v_built_items||jsonb_build_object('id',v_pack.id,'type','pack','code',v_pack.id::text,'name',v_pack.name,'qty',v_qty,'price',v_unit_price,'items',v_pack_items);
    elsif v_type='product' then
      select stock,price,name,code into v_stock,v_price,v_pname,v_pcode from products where id=v_pid for update;
      if v_stock is null then raise exception 'PRODUCT_NOT_FOUND: %',v_pid; end if;
      if v_price is null or v_price<0 then raise exception 'INVALID_PRODUCT_PRICE: %',v_pid; end if;
      select * into v_discount from product_discounts d where d.product_id=v_pid and d.active and (d.starts_at is null or d.starts_at<=now()) and (d.ends_at is null or d.ends_at>now()) limit 1;
      if found then
        if v_discount.discount_type='percent' then v_unit_price:=greatest(0,round(v_price*(100-v_discount.discount_value)/100.0))::int; else v_unit_price:=greatest(0,v_price-v_discount.discount_value); end if;
      else v_unit_price:=v_price; end if;
      v_req_qty:=coalesce((v_requirements->>v_pid)::int,0)+v_qty; v_requirements:=jsonb_set(v_requirements,array[v_pid],to_jsonb(v_req_qty),true);
      v_total_qty:=v_total_qty+v_qty; if v_total_qty>100 then raise exception 'INVALID_ITEMS'; end if;
      v_real_subtotal:=v_real_subtotal+(v_unit_price::bigint*v_qty);
      v_built_items:=v_built_items||jsonb_build_object('id',v_pid,'type','product','code',v_pcode,'name',v_pname,'qty',v_qty,'price',v_unit_price,'original_price',v_price);
    else raise exception 'INVALID_ITEM_TYPE'; end if;
  end loop;

  for v_agg in select key as pid, value::int as qty from jsonb_each_text(v_requirements) loop
    select stock into v_stock from products where id=v_agg.pid for update;
    if v_stock is null then raise exception 'PRODUCT_NOT_FOUND: %',v_agg.pid; end if;
    if v_stock<v_agg.qty then raise exception 'OUT_OF_STOCK: %',v_agg.pid; end if;
  end loop;
  for v_agg in select key as pid, value::int as qty from jsonb_each_text(v_requirements) loop update products set stock=stock-v_agg.qty where id=v_agg.pid; end loop;

  insert into customers(phone,name,address,postal_code) values(p_phone,p_name,p_address,p_postal_code) on conflict(phone) do update set name=excluded.name,address=excluded.address,postal_code=excluded.postal_code;
  loop
    v_attempt:=v_attempt+1; v_code:='KG-'||floor(random()*900000+100000)::text;
    begin
      insert into orders(order_code,name,phone,address,shipping,items,subtotal,status,payment_method,payment_status,payment_ref,province,city,postal_code,packaging_option,packaging_fee,via_fallback)
      values(v_code,p_name,p_phone,p_address,p_shipping,v_built_items,v_real_subtotal::int,0,p_payment_method,case when p_payment_method='card' then 'awaiting_confirmation' else 'paid_cod' end,p_payment_ref,p_province,p_city,p_postal_code,v_norm_packaging,v_real_packaging_fee,p_via_fallback); exit;
    exception when unique_violation then if v_attempt>=5 then raise exception 'ORDER_CODE_COLLISION_RETRY_EXCEEDED'; end if; end;
  end loop;
  return json_build_object('order_code',v_code,'coupon',null,'subtotal',v_real_subtotal,'packaging_fee',v_real_packaging_fee);
end; $$;

-- Tighten fixed-amount product discounts: they cannot exceed the product's current price.
create or replace function public.admin_save_product_discount(
  p_id uuid,p_product_id text,p_title text,p_discount_type text,p_discount_value integer,p_active boolean,p_starts_at timestamptz,p_ends_at timestamptz
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_id uuid; v_price int;
begin
  if (auth.jwt()->>'email') <> 'mohammadmoradi.1373m@gmail.com' then raise exception 'NOT_AUTHORIZED'; end if;
  select price into v_price from products where id=p_product_id;
  if v_price is null then raise exception 'PRODUCT_NOT_FOUND'; end if;
  if p_discount_type not in ('percent','fixed') then raise exception 'INVALID_DISCOUNT_TYPE'; end if;
  if p_discount_value<0 or (p_discount_type='percent' and (p_discount_value<1 or p_discount_value>100)) then raise exception 'INVALID_DISCOUNT_VALUE'; end if;
  if p_discount_type='fixed' and p_discount_value>v_price then raise exception 'DISCOUNT_EXCEEDS_PRICE'; end if;
  if p_ends_at is not null and p_starts_at is not null and p_ends_at<=p_starts_at then raise exception 'INVALID_DATES'; end if;
  insert into product_discounts(id,product_id,title,discount_type,discount_value,active,starts_at,ends_at,updated_at)
  values(coalesce(p_id,gen_random_uuid()),p_product_id,coalesce(nullif(btrim(p_title),''),'تخفیف ویژه'),p_discount_type,p_discount_value,coalesce(p_active,true),p_starts_at,p_ends_at,now())
  on conflict(product_id) do update set title=excluded.title,discount_type=excluded.discount_type,discount_value=excluded.discount_value,active=excluded.active,starts_at=excluded.starts_at,ends_at=excluded.ends_at,updated_at=now()
  returning id into v_id; return v_id;
end; $$;

create table if not exists public.product_discounts (
  id uuid primary key default gen_random_uuid(),
  product_id text not null references public.products(id) on delete cascade,
  title text not null default 'تخفیف ویژه',
  discount_type text not null check (discount_type in ('percent','fixed')),
  discount_value integer not null check (discount_value >= 0),
  active boolean not null default true,
  starts_at timestamptz,
  ends_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint product_discounts_product_unique unique (product_id),
  constraint product_discounts_dates_valid check (ends_at is null or starts_at is null or ends_at > starts_at),
  constraint product_discounts_percent_valid check (discount_type <> 'percent' or discount_value between 1 and 100)
);

create table if not exists public.packs (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  description text,
  pricing_type text not null check (pricing_type in ('percent','fixed')),
  discount_value integer not null default 0 check (discount_value >= 0),
  image_url text,
  active boolean not null default true,
  starts_at timestamptz,
  ends_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint packs_dates_valid check (ends_at is null or starts_at is null or ends_at > starts_at),
  constraint packs_percent_valid check (pricing_type <> 'percent' or discount_value between 0 and 100)
);

create table if not exists public.pack_items (
  pack_id uuid not null references public.packs(id) on delete cascade,
  product_id text not null references public.products(id) on delete restrict,
  quantity integer not null default 1 check (quantity between 1 and 100),
  created_at timestamptz not null default now(),
  primary key (pack_id, product_id)
);

create index if not exists product_discounts_active_idx on public.product_discounts(active, starts_at, ends_at);
create index if not exists packs_active_idx on public.packs(active, starts_at, ends_at);
create index if not exists pack_items_product_idx on public.pack_items(product_id);

alter table public.product_discounts enable row level security;
alter table public.packs enable row level security;
alter table public.pack_items enable row level security;

drop policy if exists product_discounts_admin_select on public.product_discounts;
drop policy if exists product_discounts_admin_insert on public.product_discounts;
drop policy if exists product_discounts_admin_update on public.product_discounts;
drop policy if exists product_discounts_admin_delete on public.product_discounts;
create policy product_discounts_admin_select on public.product_discounts for select using ((auth.jwt()->>'email')='mohammadmoradi.1373m@gmail.com');
create policy product_discounts_admin_insert on public.product_discounts for insert with check ((auth.jwt()->>'email')='mohammadmoradi.1373m@gmail.com');
create policy product_discounts_admin_update on public.product_discounts for update using ((auth.jwt()->>'email')='mohammadmoradi.1373m@gmail.com') with check ((auth.jwt()->>'email')='mohammadmoradi.1373m@gmail.com');
create policy product_discounts_admin_delete on public.product_discounts for delete using ((auth.jwt()->>'email')='mohammadmoradi.1373m@gmail.com');

drop policy if exists packs_admin_select on public.packs;
create policy packs_admin_select on public.packs for select using ((auth.jwt()->>'email')='mohammadmoradi.1373m@gmail.com');
drop policy if exists pack_items_admin_select on public.pack_items;
create policy pack_items_admin_select on public.pack_items for select using ((auth.jwt()->>'email')='mohammadmoradi.1373m@gmail.com');

create or replace function public.admin_save_product_discount(
  p_id uuid,p_product_id text,p_title text,p_discount_type text,p_discount_value integer,p_active boolean,p_starts_at timestamptz,p_ends_at timestamptz
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_id uuid; v_price int;
begin
  if (auth.jwt()->>'email') <> 'mohammadmoradi.1373m@gmail.com' then raise exception 'NOT_AUTHORIZED'; end if;
  select price into v_price from products where id=p_product_id;
  if v_price is null then raise exception 'PRODUCT_NOT_FOUND'; end if;
  if p_discount_type not in ('percent','fixed') then raise exception 'INVALID_DISCOUNT_TYPE'; end if;
  if p_discount_value<0 or (p_discount_type='percent' and (p_discount_value<1 or p_discount_value>100)) then raise exception 'INVALID_DISCOUNT_VALUE'; end if;
  if p_discount_type='fixed' and p_discount_value>v_price then raise exception 'DISCOUNT_EXCEEDS_PRICE'; end if;
  if p_ends_at is not null and p_starts_at is not null and p_ends_at<=p_starts_at then raise exception 'INVALID_DATES'; end if;
  insert into product_discounts(id,product_id,title,discount_type,discount_value,active,starts_at,ends_at,updated_at)
  values(coalesce(p_id,gen_random_uuid()),p_product_id,coalesce(nullif(btrim(p_title),''),'تخفیف ویژه'),p_discount_type,p_discount_value,coalesce(p_active,true),p_starts_at,p_ends_at,now())
  on conflict(product_id) do update set title=excluded.title,discount_type=excluded.discount_type,discount_value=excluded.discount_value,active=excluded.active,starts_at=excluded.starts_at,ends_at=excluded.ends_at,updated_at=now()
  returning id into v_id; return v_id;
end; $$;

create or replace function public.admin_delete_product_discount(p_id uuid) returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if (auth.jwt()->>'email') <> 'mohammadmoradi.1373m@gmail.com' then raise exception 'NOT_AUTHORIZED'; end if;
  delete from product_discounts where id=p_id; return true;
end; $$;

create or replace function public.admin_save_pack(
  p_id uuid,p_name text,p_slug text,p_description text,p_pricing_type text,p_discount_value integer,p_image_url text,p_active boolean,p_starts_at timestamptz,p_ends_at timestamptz,p_items jsonb
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_id uuid:=coalesce(p_id,gen_random_uuid()); v_count int; v_dup int; v_base bigint:=0;
begin
  if (auth.jwt()->>'email') <> 'mohammadmoradi.1373m@gmail.com' then raise exception 'NOT_AUTHORIZED'; end if;
  if nullif(btrim(p_name),'') is null or length(btrim(p_name))>160 then raise exception 'INVALID_PACK_NAME'; end if;
  if nullif(btrim(p_slug),'') is null or p_slug !~ '^[a-z0-9-]{2,80}$' then raise exception 'INVALID_PACK_SLUG'; end if;
  if p_pricing_type not in ('percent','fixed') then raise exception 'INVALID_PACK_PRICING'; end if;
  if p_discount_value<0 or (p_pricing_type='percent' and p_discount_value>100) then raise exception 'INVALID_PACK_DISCOUNT'; end if;
  if p_ends_at is not null and p_starts_at is not null and p_ends_at<=p_starts_at then raise exception 'INVALID_DATES'; end if;
  if jsonb_typeof(p_items)<>'array' then raise exception 'INVALID_PACK_ITEMS'; end if;
  select count(*),count(distinct x.product_id) into v_count,v_dup from jsonb_to_recordset(p_items) as x(product_id text,quantity int);
  if v_count<2 or v_count>10 or v_dup<>v_count then raise exception 'PACK_MUST_HAVE_2_TO_10_PRODUCTS'; end if;
  if exists(select 1 from jsonb_to_recordset(p_items) as x(product_id text,quantity int) where nullif(btrim(product_id),'') is null or quantity is null or quantity<1 or quantity>100) then raise exception 'INVALID_PACK_ITEM'; end if;
  if exists(select 1 from jsonb_to_recordset(p_items) as x(product_id text,quantity int) left join products p on p.id=x.product_id where p.id is null) then raise exception 'PACK_PRODUCT_NOT_FOUND'; end if;
  select coalesce(sum(p.price*x.quantity),0) into v_base from jsonb_to_recordset(p_items) as x(product_id text,quantity int) join products p on p.id=x.product_id;
  if p_pricing_type='fixed' and p_discount_value>v_base then raise exception 'PACK_PRICE_TOO_HIGH'; end if;
  insert into packs(id,name,slug,description,pricing_type,discount_value,image_url,active,starts_at,ends_at,updated_at)
  values(v_id,btrim(p_name),lower(btrim(p_slug)),nullif(btrim(p_description),''),p_pricing_type,p_discount_value,nullif(btrim(p_image_url),''),coalesce(p_active,true),p_starts_at,p_ends_at,now())
  on conflict(id) do update set name=excluded.name,slug=excluded.slug,description=excluded.description,pricing_type=excluded.pricing_type,discount_value=excluded.discount_value,image_url=excluded.image_url,active=excluded.active,starts_at=excluded.starts_at,ends_at=excluded.ends_at,updated_at=now();
  delete from pack_items where pack_id=v_id;
  insert into pack_items(pack_id,product_id,quantity) select v_id,x.product_id,x.quantity from jsonb_to_recordset(p_items) as x(product_id text,quantity int);
  return v_id;
end; $$;

create or replace function public.admin_delete_pack(p_id uuid) returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if (auth.jwt()->>'email') <> 'mohammadmoradi.1373m@gmail.com' then raise exception 'NOT_AUTHORIZED'; end if;
  delete from packs where id=p_id; return true;
end; $$;

create or replace function public.get_home_offers() returns json language sql security definer set search_path=public,pg_temp as $$
  select json_build_object(
    'discounts',coalesce((select json_agg(json_build_object('id',d.id,'product_id',p.id,'title',d.title,'discount_type',d.discount_type,'discount_value',d.discount_value,'price',p.price,'discounted_price',case when d.discount_type='percent' then greatest(0,round(p.price*(100-d.discount_value)/100.0))::int else greatest(0,p.price-d.discount_value) end,'name',p.name,'stock',p.stock,'img_url',p.img_url,'images',p.images) order by d.created_at desc) from product_discounts d join products p on p.id=d.product_id where d.active and (d.starts_at is null or d.starts_at<=now()) and (d.ends_at is null or d.ends_at>now()) and p.stock>0),'[]'::json),
    'packs',coalesce((select json_agg(json_build_object('id',x.id,'name',x.name,'slug',x.slug,'description',x.description,'pricing_type',x.pricing_type,'discount_value',x.discount_value,'image_url',x.image_url,'base_price',x.base_price,'price',x.pack_price,'items',x.items) order by x.created_at desc) from (select pk.*,coalesce(sum(p.price*pi.quantity),0)::bigint base_price,(case when pk.pricing_type='percent' then greatest(0,round(coalesce(sum(p.price*pi.quantity),0)*(100-pk.discount_value)/100.0))::bigint else greatest(0,coalesce(sum(p.price*pi.quantity),0)-pk.discount_value)::bigint end) pack_price,json_agg(json_build_object('product_id',p.id,'name',p.name,'quantity',pi.quantity,'price',p.price,'stock',p.stock,'img_url',p.img_url,'images',p.images) order by p.name) items from packs pk join pack_items pi on pi.pack_id=pk.id join products p on p.id=pi.product_id where pk.active and (pk.starts_at is null or pk.starts_at<=now()) and (pk.ends_at is null or pk.ends_at>now()) group by pk.id) x),'[]'::json)
  );
$$;

grant execute on function public.get_home_offers() to anon,authenticated;
grant execute on function public.admin_save_product_discount(uuid,text,text,text,integer,boolean,timestamptz,timestamptz) to authenticated;
grant execute on function public.admin_delete_product_discount(uuid) to authenticated;
grant execute on function public.admin_save_pack(uuid,text,text,text,text,integer,text,boolean,timestamptz,timestamptz,jsonb) to authenticated;
grant execute on function public.admin_delete_pack(uuid) to authenticated;

create or replace function public.create_order(
  p_name text, p_phone text, p_address text, p_shipping text, p_items jsonb, p_subtotal integer,
  p_payment_method text default 'cod', p_payment_ref text default null, p_province text default null,
  p_city text default null, p_postal_code text default null, p_packaging_option text default 'postpay',
  p_packaging_fee integer default 0, p_via_fallback boolean default false
) returns json language plpgsql security definer set search_path=public,private,pg_temp as $$
declare
  v_code text; v_elem jsonb; v_agg record; v_stock int; v_price int; v_pname text; v_pcode text;
  v_real_subtotal bigint:=0; v_real_packaging_fee int:=0; v_norm_packaging text; v_built_items jsonb:='[]'::jsonb;
  v_attempt int:=0; v_total_qty int:=0; v_phone_key text; v_window_start timestamptz; v_order_count int; v_phone_limit int;
  v_headers json; v_ip text; v_ip_key text; v_ip_window_start timestamptz; v_ip_order_count int;
  v_type text; v_pid text; v_qty int; v_unit_price int; v_base bigint; v_pack jsonb; v_pack_items jsonb; v_pack_id uuid;
  v_requirements jsonb:='{}'::jsonb; v_req_qty int; v_discount record;
begin
  if nullif(btrim(p_name),'') is null or length(btrim(p_name))>120 then raise exception 'INVALID_NAME'; end if;
  if p_phone is null or p_phone !~ '^09[0-9]{9}$' then raise exception 'INVALID_PHONE'; end if;
  if nullif(btrim(p_address),'') is null or length(btrim(p_address))>1000 then raise exception 'INVALID_ADDRESS'; end if;
  if nullif(btrim(p_shipping),'') is null or length(btrim(p_shipping))>80 then raise exception 'INVALID_SHIPPING'; end if;
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)<1 or jsonb_array_length(p_items)>50 then raise exception 'INVALID_ITEMS'; end if;
  if p_payment_method not in ('cod','card') then raise exception 'INVALID_PAYMENT_METHOD'; end if;
  if p_packaging_option not in ('postpay','prepaid') then raise exception 'INVALID_PACKAGING_OPTION'; end if;
  if p_postal_code is not null and length(btrim(p_postal_code))>32 then raise exception 'INVALID_POSTAL_CODE'; end if;
  if p_payment_ref is not null and length(btrim(p_payment_ref))>120 then raise exception 'INVALID_PAYMENT_REF'; end if;
  if p_province is not null and length(btrim(p_province))>100 then raise exception 'INVALID_PROVINCE'; end if;
  if p_city is not null and length(btrim(p_city))>100 then raise exception 'INVALID_CITY'; end if;

  v_phone_key:=md5(lower(btrim(p_phone))); v_phone_limit:=case when p_via_fallback then 1 else 5 end;
  insert into private.order_rate_limits(phone_key,window_start,order_count) values(v_phone_key,now(),1)
  on conflict(phone_key) do update set order_count=case when now()-private.order_rate_limits.window_start>=interval '1 hour' then 1 else private.order_rate_limits.order_count+1 end,
  window_start=case when now()-private.order_rate_limits.window_start>=interval '1 hour' then now() else private.order_rate_limits.window_start end
  returning window_start,order_count into v_window_start,v_order_count;
  if v_order_count>v_phone_limit then if p_via_fallback then raise exception 'FALLBACK_ORDER_RATE_LIMITED'; else raise exception 'ORDER_RATE_LIMITED'; end if; end if;

  v_headers:=nullif(current_setting('request.headers',true),'')::json;
  v_ip:=coalesce(nullif(btrim(v_headers->>'cf-connecting-ip'),''),nullif(btrim(split_part(coalesce(v_headers->>'x-forwarded-for',''),',',1)),''));
  if v_ip is not null then
    v_ip_key:=md5(v_ip);
    insert into private.order_ip_rate_limits(ip_hash,window_start,order_count) values(v_ip_key,now(),1)
    on conflict(ip_hash) do update set order_count=case when now()-private.order_ip_rate_limits.window_start>=interval '1 hour' then 1 else private.order_ip_rate_limits.order_count+1 end,
    window_start=case when now()-private.order_ip_rate_limits.window_start>=interval '1 hour' then now() else private.order_ip_rate_limits.window_start end
    returning window_start,order_count into v_ip_window_start,v_ip_order_count;
    if v_ip_order_count>20 then raise exception 'ORDER_IP_RATE_LIMITED'; end if;
  end if;

  if p_packaging_option='prepaid' then v_norm_packaging:='prepaid'; v_real_packaging_fee:=300000; else v_norm_packaging:='postpay'; v_real_packaging_fee:=0; end if;

  for v_elem in select value from jsonb_array_elements(p_items) loop
    v_type:=coalesce(v_elem->>'type','product'); v_pid:=nullif(btrim(v_elem->>'id'),''); v_qty:=coalesce((v_elem->>'qty')::int,0);
    if v_pid is null or length(v_pid)>120 or v_qty<1 or v_qty>100 then raise exception 'INVALID_QTY: %',v_pid; end if;
    if v_type='pack' then
      begin v_pack_id:=v_pid::uuid; exception when others then raise exception 'INVALID_PACK: %',v_pid; end;
      select pk.id,pk.name,pk.pricing_type,pk.discount_value into v_pack from packs pk where pk.id=v_pack_id and pk.active and (pk.starts_at is null or pk.starts_at<=now()) and (pk.ends_at is null or pk.ends_at>now());
      if v_pack.id is null then raise exception 'PACK_NOT_FOUND: %',v_pid; end if;
      v_base:=0; v_pack_items:='[]'::jsonb;
      for v_agg in select pi.product_id,pi.quantity,p.stock,p.price,p.name,p.code from pack_items pi join products p on p.id=pi.product_id where pi.pack_id=v_pack_id order by p.name for update of p loop
        if v_agg.quantity<1 or v_agg.stock<0 or v_agg.price<0 then raise exception 'INVALID_PACK_ITEM'; end if;
        v_req_qty:=coalesce((v_requirements->>v_agg.product_id)::int,0)+(v_agg.quantity*v_qty); v_requirements:=jsonb_set(v_requirements,array[v_agg.product_id],to_jsonb(v_req_qty),true);
        v_total_qty:=v_total_qty+(v_agg.quantity*v_qty); if v_total_qty>100 then raise exception 'INVALID_ITEMS'; end if;
        v_base:=v_base+(v_agg.price::bigint*v_agg.quantity);
        v_pack_items:=v_pack_items||jsonb_build_object('product_id',v_agg.product_id,'code',v_agg.code,'name',v_agg.name,'quantity',v_agg.quantity,'unit_price',v_agg.price);
      end loop;
      if jsonb_array_length(v_pack_items)<2 or jsonb_array_length(v_pack_items)>10 then raise exception 'PACK_INVALID_ITEM_COUNT'; end if;
      if v_pack.pricing_type='percent' then v_unit_price:=greatest(0,round(v_base*(100-v_pack.discount_value)/100.0))::int; else if v_pack.discount_value>v_base then raise exception 'PACK_PRICE_INVALID'; end if; v_unit_price:=greatest(0,v_base-v_pack.discount_value)::int; end if;
      v_real_subtotal:=v_real_subtotal+(v_unit_price::bigint*v_qty);
      v_built_items:=v_built_items||jsonb_build_object('id',v_pack.id,'type','pack','code',v_pack.id::text,'name',v_pack.name,'qty',v_qty,'price',v_unit_price,'items',v_pack_items);
    elsif v_type='product' then
      select stock,price,name,code into v_stock,v_price,v_pname,v_pcode from products where id=v_pid for update;
      if v_stock is null then raise exception 'PRODUCT_NOT_FOUND: %',v_pid; end if;
      if v_price is null or v_price<0 then raise exception 'INVALID_PRODUCT_PRICE: %',v_pid; end if;
      select * into v_discount from product_discounts d where d.product_id=v_pid and d.active and (d.starts_at is null or d.starts_at<=now()) and (d.ends_at is null or d.ends_at>now()) limit 1;
      if found then
        if v_discount.discount_type='percent' then v_unit_price:=greatest(0,round(v_price*(100-v_discount.discount_value)/100.0))::int; else v_unit_price:=greatest(0,v_price-v_discount.discount_value); end if;
      else v_unit_price:=v_price; end if;
      v_req_qty:=coalesce((v_requirements->>v_pid)::int,0)+v_qty; v_requirements:=jsonb_set(v_requirements,array[v_pid],to_jsonb(v_req_qty),true);
      v_total_qty:=v_total_qty+v_qty; if v_total_qty>100 then raise exception 'INVALID_ITEMS'; end if;
      v_real_subtotal:=v_real_subtotal+(v_unit_price::bigint*v_qty);
      v_built_items:=v_built_items||jsonb_build_object('id',v_pid,'type','product','code',v_pcode,'name',v_pname,'qty',v_qty,'price',v_unit_price,'original_price',v_price);
    else raise exception 'INVALID_ITEM_TYPE'; end if;
  end loop;

  for v_agg in select key as pid, value::int as qty from jsonb_each_text(v_requirements) loop
    select stock into v_stock from products where id=v_agg.pid for update;
    if v_stock is null then raise exception 'PRODUCT_NOT_FOUND: %',v_agg.pid; end if;
    if v_stock<v_agg.qty then raise exception 'OUT_OF_STOCK: %',v_agg.pid; end if;
  end loop;
  for v_agg in select key as pid, value::int as qty from jsonb_each_text(v_requirements) loop update products set stock=stock-v_agg.qty where id=v_agg.pid; end loop;

  insert into customers(phone,name,address,postal_code) values(p_phone,p_name,p_address,p_postal_code) on conflict(phone) do update set name=excluded.name,address=excluded.address,postal_code=excluded.postal_code;
  loop
    v_attempt:=v_attempt+1; v_code:='KG-'||floor(random()*900000+100000)::text;
    begin
      insert into orders(order_code,name,phone,address,shipping,items,subtotal,status,payment_method,payment_status,payment_ref,province,city,postal_code,packaging_option,packaging_fee,via_fallback)
      values(v_code,p_name,p_phone,p_address,p_shipping,v_built_items,v_real_subtotal::int,0,p_payment_method,case when p_payment_method='card' then 'awaiting_confirmation' else 'paid_cod' end,p_payment_ref,p_province,p_city,p_postal_code,v_norm_packaging,v_real_packaging_fee,p_via_fallback); exit;
    exception when unique_violation then if v_attempt>=5 then raise exception 'ORDER_CODE_COLLISION_RETRY_EXCEEDED'; end if; end;
  end loop;
  return json_build_object('order_code',v_code,'coupon',null,'subtotal',v_real_subtotal,'packaging_fee',v_real_packaging_fee);
end; $$;

-- Tighten fixed-amount product discounts: they cannot exceed the product's current price.
create or replace function public.admin_save_product_discount(
  p_id uuid,p_product_id text,p_title text,p_discount_type text,p_discount_value integer,p_active boolean,p_starts_at timestamptz,p_ends_at timestamptz
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_id uuid; v_price int;
begin
  if (auth.jwt()->>'email') <> 'mohammadmoradi.1373m@gmail.com' then raise exception 'NOT_AUTHORIZED'; end if;
  select price into v_price from products where id=p_product_id;
  if v_price is null then raise exception 'PRODUCT_NOT_FOUND'; end if;
  if p_discount_type not in ('percent','fixed') then raise exception 'INVALID_DISCOUNT_TYPE'; end if;
  if p_discount_value<0 or (p_discount_type='percent' and (p_discount_value<1 or p_discount_value>100)) then raise exception 'INVALID_DISCOUNT_VALUE'; end if;
  if p_discount_type='fixed' and p_discount_value>v_price then raise exception 'DISCOUNT_EXCEEDS_PRICE'; end if;
  if p_ends_at is not null and p_starts_at is not null and p_ends_at<=p_starts_at then raise exception 'INVALID_DATES'; end if;
  insert into product_discounts(id,product_id,title,discount_type,discount_value,active,starts_at,ends_at,updated_at)
  values(coalesce(p_id,gen_random_uuid()),p_product_id,coalesce(nullif(btrim(p_title),''),'تخفیف ویژه'),p_discount_type,p_discount_value,coalesce(p_active,true),p_starts_at,p_ends_at,now())
  on conflict(product_id) do update set title=excluded.title,discount_type=excluded.discount_type,discount_value=excluded.discount_value,active=excluded.active,starts_at=excluded.starts_at,ends_at=excluded.ends_at,updated_at=now()
  returning id into v_id; return v_id;
end; $$;
