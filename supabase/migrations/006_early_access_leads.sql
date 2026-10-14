create table public.early_access_leads (
  id uuid primary key default gen_random_uuid(),
  full_name text not null check (char_length(trim(full_name)) between 2 and 80),
  phone text not null check (char_length(trim(phone)) between 7 and 30),
  audience text not null check (audience in ('customer','specialist')),
  specialty text,
  consent boolean not null default false check (consent = true),
  source text not null default 'website' check (source = 'website'),
  created_at timestamptz not null default now(),
  constraint early_access_specialty_check check (
    (audience = 'customer' and specialty is null)
    or (audience = 'specialist' and specialty is not null and char_length(trim(specialty)) between 2 and 120)
  )
);
alter table public.early_access_leads enable row level security;
revoke all on table public.early_access_leads from public, anon, authenticated;
grant insert on table public.early_access_leads to anon, authenticated;
create policy "Public can submit valid early access leads"
on public.early_access_leads
for insert to anon, authenticated
with check (
  char_length(trim(full_name)) between 2 and 80
  and char_length(trim(phone)) between 7 and 30
  and consent = true
  and source = 'website'
  and audience in ('customer','specialist')
  and (
    (audience = 'customer' and specialty is null)
    or (audience = 'specialist' and specialty is not null and char_length(trim(specialty)) between 2 and 120)
  )
);
