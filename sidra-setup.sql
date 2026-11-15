-- Sidra Perfume: مشروع Supabase جديد ومنفصل. شغّل الملف كله مرة واحدة في SQL Editor.
-- بعدها: Authentication > Users > Add user (إيميلك وباسورد)، وبعدين شغّل السطر اللي في الآخر (sp_owner).
create table if not exists sp_owner(user_id uuid primary key references auth.users(id) on delete cascade);
create or replace function sp_is_owner() returns boolean language sql stable security definer set search_path=public as
$$ select exists(select 1 from sp_owner where user_id=auth.uid()) $$;

create table if not exists sp_perfumes(id bigint generated always as identity primary key, name text not null, category text, notes text, image_url text,
  active boolean not null default true, bulk_ml numeric not null default 0, cost_per_ml numeric not null default 0, created_at timestamptz not null default now());
create table if not exists sp_sizes(id bigint generated always as identity primary key, perfume_id bigint not null references sp_perfumes(id) on delete cascade,
  ml numeric not null check(ml>0), price numeric not null check(price>=0), barcode text unique, active boolean not null default true);
create table if not exists sp_purchases(id bigint generated always as identity primary key, perfume_id bigint not null references sp_perfumes(id),
  ml numeric not null check(ml>0), cost_total numeric not null check(cost_total>=0), supplier text, created_at timestamptz not null default now());
create table if not exists sp_customers(id bigint generated always as identity primary key, name text, phone text unique, address text, created_at timestamptz not null default now());
create table if not exists sp_sales(id bigint generated always as identity (start with 1001) primary key, customer_id bigint references sp_customers(id),
  kind text not null check(kind in ('sale','gift','return')), total numeric not null default 0, created_at timestamptz not null default now());
create table if not exists sp_sale_items(id bigint generated always as identity primary key, sale_id bigint not null references sp_sales(id) on delete cascade,
  size_id bigint references sp_sizes(id), perfume_id bigint references sp_perfumes(id), ml numeric not null, qty int not null, price numeric not null);

-- كل الجداول للمالك بس (المتجر العلني هيتعمل لاحقًا عن طريق View بدون سعر التكلفة)
do $$ declare t text; begin
 foreach t in array array['sp_perfumes','sp_sizes','sp_purchases','sp_customers','sp_sales','sp_sale_items'] loop
  execute format('alter table %I enable row level security',t);
  execute format('drop policy if exists owner_all on %I',t);
  execute format('create policy owner_all on %I for all to authenticated using (sp_is_owner()) with check (sp_is_owner())',t);
 end loop; end $$;
alter table sp_owner enable row level security;
drop policy if exists own_row on sp_owner; create policy own_row on sp_owner for select to authenticated using (user_id=auth.uid());

-- الشراء بيزوّد المخزون بالمل ويحسب متوسط تكلفة المل
create or replace function sp_purchase_apply() returns trigger language plpgsql as $$
begin update sp_perfumes set cost_per_ml=(bulk_ml*cost_per_ml+new.cost_total)/(bulk_ml+new.ml), bulk_ml=bulk_ml+new.ml where id=new.perfume_id; return new; end $$;
drop trigger if exists sp_purchase_apply on sp_purchases;
create trigger sp_purchase_apply after insert on sp_purchases for each row execute function sp_purchase_apply();

-- البيع / الهدية / المرتجع: بيخصم (أو يرجّع) المل حسب حجم الزجاجة، ويرفض لو المخزون مش كفاية
create or replace function sp_sell(p_kind text, p_name text, p_phone text, p_items jsonb) returns bigint
language plpgsql security definer set search_path=public as $$
declare cid bigint; sid bigint; it jsonb; z sp_sizes; q int; pr numeric; tot numeric:=0; bm numeric;
begin
 if not sp_is_owner() then raise exception 'مش مسموح'; end if;
 if p_kind not in ('sale','gift','return') then raise exception 'نوع غير صحيح'; end if;
 if nullif(btrim(coalesce(p_phone,'')),'') is not null then
  insert into sp_customers(name,phone) values (coalesce(nullif(btrim(p_name),''),'عميل'), btrim(p_phone))
  on conflict (phone) do update set name=coalesce(nullif(btrim(p_name),''), sp_customers.name) returning id into cid;
 end if;
 insert into sp_sales(customer_id,kind) values (cid,p_kind) returning id into sid;
 for it in select * from jsonb_array_elements(p_items) loop
  select * into z from sp_sizes where id=(it->>'size_id')::bigint;
  if not found then raise exception 'حجم غير موجود'; end if;
  q:=(it->>'qty')::int; if q<=0 then raise exception 'كمية غير صحيحة'; end if;
  pr:=case when p_kind='gift' then 0 else z.price end; tot:=tot+pr*q;
  update sp_perfumes set bulk_ml=bulk_ml+(case when p_kind='return' then 1 else -1 end)*z.ml*q where id=z.perfume_id returning bulk_ml into bm;
  if bm<0 then raise exception 'المخزون مش كفاية'; end if;
  insert into sp_sale_items(sale_id,size_id,perfume_id,ml,qty,price) values (sid,z.id,z.perfume_id,z.ml,q,pr);
 end loop;
 update sp_sales set total=case when p_kind='return' then -tot else tot end where id=sid;
 return sid;
end $$;
revoke all on function sp_sell(text,text,text,jsonb) from public, anon;
grant execute on function sp_sell(text,text,text,jsonb) to authenticated;

-- آخر خطوة (بعد ما تضيف حسابك في Authentication > Users):
-- insert into sp_owner(user_id) select id from auth.users where email='ايميلك@example.com';
