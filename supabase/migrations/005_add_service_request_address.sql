alter table public.service_requests
  add column if not exists address text;

comment on column public.service_requests.address is
  'Customer-provided service location. Exact address is not returned to specialists before assignment.';
