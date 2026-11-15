-- Sidra Perfume: المتجر العلني + طلبات الأونلاين. شغّله بعد sidra-setup.sql (نفس المشروع الجديد بس). آمن لو اتشغّل تاني.
create table if not exists sp_orders(id bigint generated always as identity (start with 5001) primary key, name text not null, phone text not null, address text, note text,
  status text not null default 'new' check(status in ('new','ready','delivered','cancelled')), total numeric not null default 0, created_at timestamptz not null default now());
create table if not exists sp_order_items(id bigint generated always as identity primary key, order_id bigint not null references sp_orders(id) on delete cascade,
  size_id bigint not null references sp_sizes(id), qty int not null check(qty>0), price numeric not null);
alter table sp_orders enable row level security; alter table sp_order_items enable row level security;
drop policy if exists owner_all on sp_orders; create policy owner_all on sp_orders for all to authenticated using (sp_is_owner()) with check (sp_is_owner());
drop policy if exists owner_all on sp_order_items; create policy owner_all on sp_order_items for all to authenticated using (sp_is_owner()) with check (sp_is_owner());

-- كتالوج علني: اسم وسعر وحجم وهل متاح، من غير المخزون بالمل ولا التكلفة
create or replace view sp_catalog as
 select s.id as size_id, p.id as perfume_id, p.name, p.category, p.notes, p.image_url, s.ml, s.price, (p.bulk_ml >= s.ml) as in_stock
 from sp_sizes s join sp_perfumes p on p.id=s.perfume_id where s.active and p.active;
grant select on sp_catalog to anon, authenticated;

-- العميل بيبعت طلب من غير تسجيل. السعر بيتحسب من السيرفر، وفيه حد للإساءة (5 طلبات/ساعة لنفس التليفون)
create or replace function sp_place_order(p_name text, p_phone text, p_address text, p_note text, p_items jsonb) returns bigint
language plpgsql security definer set search_path=public as $$
declare oid bigint; it jsonb; z sp_sizes; q int; tot numeric:=0;
begin
 if length(btrim(coalesce(p_name,'')))<2 or length(regexp_replace(coalesce(p_phone,''),'\D','','g'))<10 then raise exception 'اكتب الاسم ورقم تليفون صحيح'; end if;
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items) not between 1 and 20 then raise exception 'السلة فاضية'; end if;
 if (select count(*) from sp_orders where phone=btrim(p_phone) and created_at>now()-interval '1 hour')>=5 then raise exception 'طلبات كتير، جرّب بعد شوية'; end if;
 insert into sp_orders(name,phone,address,note) values (left(btrim(p_name),80), left(btrim(p_phone),20), left(p_address,300), left(p_note,300)) returning id into oid;
 for it in select * from jsonb_array_elements(p_items) loop
  select * into z from sp_sizes where id=(it->>'size_id')::bigint and active;
  if not found then raise exception 'حجم غير متاح'; end if;
  q:=(it->>'qty')::int; if q<1 or q>10 then raise exception 'كمية غير صحيحة'; end if;
  insert into sp_order_items(order_id,size_id,qty,price) values (oid,z.id,q,z.price); tot:=tot+z.price*q;
 end loop;
 update sp_orders set total=tot where id=oid; return oid;
end $$;
revoke all on function sp_place_order(text,text,text,text,jsonb) from public;
grant execute on function sp_place_order(text,text,text,text,jsonb) to anon, authenticated;
