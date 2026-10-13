create table if not exists public.request_arrival_codes (
 request_id uuid primary key references public.service_requests(id) on delete cascade,
 customer_id uuid not null references public.profiles(id) on delete cascade,
 code text not null check (code ~ '^[0-9]{4}$'),
 verified_at timestamptz,
 failed_attempts integer not null default 0 check (failed_attempts >= 0),
 locked_until timestamptz,
 created_at timestamptz not null default now()
);
create table if not exists public.service_quotes (
 id uuid primary key default gen_random_uuid(),
 request_id uuid not null references public.service_requests(id) on delete cascade,
 specialist_id uuid not null references public.profiles(id) on delete cascade,
 trip_fee numeric(12,2) not null default 0 check (trip_fee >= 0),
 labor_cost numeric(12,2) not null check (labor_cost >= 0),
 materials_cost numeric(12,2) not null default 0 check (materials_cost >= 0),
 total numeric(12,2) generated always as (trip_fee + labor_cost + materials_cost) stored,
 status text not null default 'pending' check (status in ('pending','accepted','rejected','superseded')),
 customer_decided_at timestamptz,
 created_at timestamptz not null default now()
);
create index if not exists service_quotes_request_created_idx on public.service_quotes(request_id, created_at desc);
create index if not exists service_quotes_specialist_idx on public.service_quotes(specialist_id, created_at desc);
alter table public.request_arrival_codes enable row level security;
alter table public.service_quotes enable row level security;
drop policy if exists "Customers can view their arrival code" on public.request_arrival_codes;
create policy "Customers can view their arrival code" on public.request_arrival_codes for select to authenticated using (customer_id = (select auth.uid()));
drop policy if exists "Participants can view request quotes" on public.service_quotes;
create policy "Participants can view request quotes" on public.service_quotes for select to authenticated using (exists (select 1 from public.service_requests r where r.id = service_quotes.request_id and (r.customer_id = (select auth.uid()) or r.specialist_id = (select auth.uid()))));
grant select on public.request_arrival_codes, public.service_quotes to authenticated;
revoke insert, update, delete on public.request_arrival_codes, public.service_quotes from anon, authenticated;
create or replace function public.create_request_arrival_code() returns trigger language plpgsql security definer set search_path = '' as $$
begin
 insert into public.request_arrival_codes(request_id,customer_id,code) values(new.id,new.customer_id,lpad((floor(random()*10000))::integer::text,4,'0')) on conflict(request_id) do nothing;
 return new;
end; $$;
drop trigger if exists service_request_create_arrival_code on public.service_requests;
create trigger service_request_create_arrival_code after insert on public.service_requests for each row execute function public.create_request_arrival_code();
insert into public.request_arrival_codes(request_id,customer_id,code) select r.id,r.customer_id,lpad((floor(random()*10000))::integer::text,4,'0') from public.service_requests r where r.customer_id is not null on conflict(request_id) do nothing;
create or replace function public.verify_request_arrival(p_request_id uuid,p_code text) returns boolean language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_request public.service_requests%rowtype; v_code public.request_arrival_codes%rowtype;
begin
 if v_uid is null then raise exception 'Требуется авторизация'; end if;
 select * into v_request from public.service_requests where id=p_request_id for update;
 if not found then raise exception 'Заказ не найден'; end if;
 if v_request.specialist_id is distinct from v_uid then raise exception 'Это не ваш заказ'; end if;
 if v_request.status not in ('contacted','in_progress') then raise exception 'Сначала клиент должен выбрать вас'; end if;
 select * into v_code from public.request_arrival_codes where request_id=p_request_id for update;
 if not found then raise exception 'Код прибытия не найден'; end if;
 if v_code.locked_until is not null and v_code.locked_until>now() then raise exception 'Слишком много попыток. Попробуйте позже'; end if;
 if p_code is null or p_code !~ '^[0-9]{4}$' or p_code<>v_code.code then
  update public.request_arrival_codes set failed_attempts=failed_attempts+1,locked_until=case when failed_attempts+1>=8 then now()+interval '15 minutes' else locked_until end where request_id=p_request_id;
  raise exception 'Код не совпадает';
 end if;
 update public.request_arrival_codes set verified_at=coalesce(verified_at,now()),failed_attempts=0,locked_until=null where request_id=p_request_id;
 return true;
end; $$;
create or replace function public.submit_service_quote(p_request_id uuid,p_trip_fee numeric,p_labor_cost numeric,p_materials_cost numeric default 0) returns uuid language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_request public.service_requests%rowtype; v_quote_id uuid;
begin
 if v_uid is null then raise exception 'Требуется авторизация'; end if;
 if p_trip_fee is null or p_labor_cost is null or p_materials_cost is null or p_trip_fee<0 or p_labor_cost<0 or p_materials_cost<0 then raise exception 'Суммы должны быть нулевыми или положительными'; end if;
 if p_trip_fee>100000000 or p_labor_cost>100000000 or p_materials_cost>100000000 then raise exception 'Сумма слишком велика'; end if;
 select * into v_request from public.service_requests where id=p_request_id for update;
 if not found then raise exception 'Заказ не найден'; end if;
 if v_request.specialist_id is distinct from v_uid then raise exception 'Это не ваш заказ'; end if;
 if v_request.status not in ('contacted','in_progress') then raise exception 'Заказ не готов к согласованию цены'; end if;
 if not exists(select 1 from public.request_arrival_codes c where c.request_id=p_request_id and c.verified_at is not null) then raise exception 'Сначала подтвердите прибытие кодом клиента'; end if;
 update public.service_quotes set status='superseded' where request_id=p_request_id and status='pending';
 insert into public.service_quotes(request_id,specialist_id,trip_fee,labor_cost,materials_cost) values(p_request_id,v_uid,p_trip_fee,p_labor_cost,p_materials_cost) returning id into v_quote_id;
 update public.service_requests set status='contacted',updated_at=now() where id=p_request_id;
 return v_quote_id;
end; $$;
create or replace function public.accept_service_quote(p_quote_id uuid) returns uuid language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_quote public.service_quotes%rowtype; v_request public.service_requests%rowtype;
begin
 if v_uid is null then raise exception 'Требуется авторизация'; end if;
 select * into v_quote from public.service_quotes where id=p_quote_id for update;
 if not found then raise exception 'Смета не найдена'; end if;
 select * into v_request from public.service_requests where id=v_quote.request_id for update;
 if v_request.customer_id is distinct from v_uid then raise exception 'Это не ваш заказ'; end if;
 if v_quote.status<>'pending' then raise exception 'Эта смета уже не ожидает решения'; end if;
 if v_request.specialist_id is distinct from v_quote.specialist_id then raise exception 'Мастер больше не назначен на этот заказ'; end if;
 update public.service_quotes set status='superseded' where request_id=v_quote.request_id and status='pending' and id<>p_quote_id;
 update public.service_quotes set status='accepted',customer_decided_at=now() where id=p_quote_id;
 update public.service_requests set status='in_progress',updated_at=now() where id=v_quote.request_id;
 return v_quote.request_id;
end; $$;
create or replace function public.reject_service_quote(p_quote_id uuid) returns uuid language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_quote public.service_quotes%rowtype; v_request public.service_requests%rowtype;
begin
 if v_uid is null then raise exception 'Требуется авторизация'; end if;
 select * into v_quote from public.service_quotes where id=p_quote_id for update;
 if not found then raise exception 'Смета не найдена'; end if;
 select * into v_request from public.service_requests where id=v_quote.request_id for update;
 if v_request.customer_id is distinct from v_uid then raise exception 'Это не ваш заказ'; end if;
 if v_quote.status<>'pending' then raise exception 'Эта смета уже не ожидает решения'; end if;
 update public.service_quotes set status='rejected',customer_decided_at=now() where id=p_quote_id;
 return v_quote.request_id;
end; $$;
revoke all on function public.create_request_arrival_code() from public,anon,authenticated;
revoke all on function public.verify_request_arrival(uuid,text) from public,anon;
revoke all on function public.submit_service_quote(uuid,numeric,numeric,numeric) from public,anon;
revoke all on function public.accept_service_quote(uuid) from public,anon;
revoke all on function public.reject_service_quote(uuid) from public,anon;
grant execute on function public.verify_request_arrival(uuid,text) to authenticated;
grant execute on function public.submit_service_quote(uuid,numeric,numeric,numeric) to authenticated;
grant execute on function public.accept_service_quote(uuid) to authenticated;
grant execute on function public.reject_service_quote(uuid) to authenticated;
