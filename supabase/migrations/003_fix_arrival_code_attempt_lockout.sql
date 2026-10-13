create or replace function public.verify_request_arrival(p_request_id uuid,p_code text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
 v_uid uuid := auth.uid();
 v_request public.service_requests%rowtype;
 v_code public.request_arrival_codes%rowtype;
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
  update public.request_arrival_codes
   set failed_attempts=failed_attempts+1,
       locked_until=case when failed_attempts+1>=8 then now()+interval '15 minutes' else locked_until end
   where request_id=p_request_id;
  return false;
 end if;
 update public.request_arrival_codes set verified_at=coalesce(verified_at,now()),failed_attempts=0,locked_until=null where request_id=p_request_id;
 return true;
end; $$;
revoke all on function public.verify_request_arrival(uuid,text) from public,anon;
grant execute on function public.verify_request_arrival(uuid,text) to authenticated;