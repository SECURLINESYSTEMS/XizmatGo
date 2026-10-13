alter table public.service_requests
 add column if not exists material_receipt_path text,
 add column if not exists completed_at timestamptz;
update public.service_requests set completed_at=updated_at where status='completed' and completed_at is null;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('xizmatgo-receipts','xizmatgo-receipts',false,5242880,array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict(id) do update set public=false,file_size_limit=5242880,allowed_mime_types=array['image/jpeg','image/png','image/webp','application/pdf'];

drop policy if exists "Assigned specialists upload job receipts" on storage.objects;
create policy "Assigned specialists upload job receipts" on storage.objects
 for insert to authenticated
 with check (
  bucket_id='xizmatgo-receipts'
  and exists (
   select 1 from public.service_requests r
   where r.id::text=split_part(name,'/',1)
     and r.specialist_id=(select auth.uid())
     and r.status='in_progress'
     and split_part(name,'/',2)=(select auth.uid())::text
  )
 );
drop policy if exists "Order participants read job receipts" on storage.objects;
create policy "Order participants read job receipts" on storage.objects
 for select to authenticated
 using (
  bucket_id='xizmatgo-receipts'
  and exists (
   select 1 from public.service_requests r
   where r.id::text=split_part(name,'/',1)
     and (r.customer_id=(select auth.uid()) or r.specialist_id=(select auth.uid()))
  )
 );

create or replace function public.complete_service_request(p_request_id uuid,p_receipt_path text default null)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
 v_uid uuid := auth.uid();
 v_request public.service_requests%rowtype;
 v_quote public.service_quotes%rowtype;
begin
 if v_uid is null then raise exception 'Требуется авторизация'; end if;
 select * into v_request from public.service_requests where id=p_request_id for update;
 if not found then raise exception 'Заказ не найден'; end if;
 if v_request.specialist_id is distinct from v_uid then raise exception 'Это не ваш заказ'; end if;
 if v_request.status <> 'in_progress' then raise exception 'Заказ должен быть в работе, а цена — подтверждена клиентом'; end if;
 select * into v_quote from public.service_quotes where request_id=p_request_id and status='accepted' order by customer_decided_at desc nulls last limit 1;
 if not found then raise exception 'Нет сметы, подтверждённой клиентом'; end if;
 if v_quote.materials_cost > 0 and (p_receipt_path is null or btrim(p_receipt_path)='') then
  raise exception 'При расходах на материалы прикрепите чек';
 end if;
 if p_receipt_path is not null then
  if p_receipt_path not like p_request_id::text || '/' || v_uid::text || '/%' then
   raise exception 'Недопустимый путь чека';
  end if;
  if not exists(select 1 from storage.objects o where o.bucket_id='xizmatgo-receipts' and o.name=p_receipt_path) then
   raise exception 'Файл чека не найден в хранилище';
  end if;
 end if;
 update public.service_requests set status='completed',material_receipt_path=p_receipt_path,completed_at=now(),updated_at=now() where id=p_request_id;
 return true;
end; $$;
revoke all on function public.complete_service_request(uuid,text) from public,anon;
grant execute on function public.complete_service_request(uuid,text) to authenticated;