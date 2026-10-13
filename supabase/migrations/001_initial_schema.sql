create extension if not exists pgcrypto;

create type public.account_role as enum ('customer','specialist','admin');
create type public.request_status as enum ('new','contacted','in_progress','completed','cancelled');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  phone text,
  city text not null default 'Ташкент',
  role public.account_role not null default 'customer',
  avatar_url text,
  bio text,
  is_verified boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.categories (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  slug text not null unique,
  icon text not null default '✨',
  description text not null default '',
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

create table public.specialist_services (
  id uuid primary key default gen_random_uuid(),
  specialist_id uuid not null references public.profiles(id) on delete cascade,
  category_id uuid not null references public.categories(id) on delete restrict,
  title text not null,
  description text not null default '',
  price_from numeric(12,2),
  price_unit text not null default 'за услугу',
  city text not null default 'Ташкент',
  photos text[] not null default '{}',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.service_requests (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid references public.profiles(id) on delete set null,
  specialist_id uuid references public.profiles(id) on delete set null,
  category_id uuid references public.categories(id) on delete set null,
  customer_name text not null,
  customer_phone text not null,
  city text not null default 'Ташкент',
  description text not null,
  preferred_time text,
  status public.request_status not null default 'new',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.reviews (
  id uuid primary key default gen_random_uuid(),
  request_id uuid unique references public.service_requests(id) on delete set null,
  customer_id uuid not null references public.profiles(id) on delete cascade,
  specialist_id uuid not null references public.profiles(id) on delete cascade,
  rating integer not null check (rating between 1 and 5),
  comment text not null default '',
  created_at timestamptz not null default now()
);

create index specialist_services_category_city_idx on public.specialist_services(category_id, city) where is_active;
create index specialist_services_specialist_idx on public.specialist_services(specialist_id);
create index service_requests_customer_idx on public.service_requests(customer_id, created_at desc);
create index service_requests_specialist_idx on public.service_requests(specialist_id, created_at desc);
create index reviews_specialist_idx on public.reviews(specialist_id);

alter table public.profiles enable row level security;
alter table public.categories enable row level security;
alter table public.specialist_services enable row level security;
alter table public.service_requests enable row level security;
alter table public.reviews enable row level security;

create policy "Profiles are visible to signed-in users" on public.profiles
  for select to authenticated using (true);
create policy "Users create their own profile" on public.profiles
  for insert to authenticated with check (auth.uid() = id);
create policy "Users update their own profile" on public.profiles
  for update to authenticated using (auth.uid() = id) with check (auth.uid() = id);

create policy "Active categories are public" on public.categories
  for select to anon, authenticated using (is_active);

create policy "Active specialist services are public" on public.specialist_services
  for select to anon, authenticated using (is_active);
create policy "Specialists create their own services" on public.specialist_services
  for insert to authenticated with check (auth.uid() = specialist_id);
create policy "Specialists update their own services" on public.specialist_services
  for update to authenticated using (auth.uid() = specialist_id) with check (auth.uid() = specialist_id);
create policy "Specialists delete their own services" on public.specialist_services
  for delete to authenticated using (auth.uid() = specialist_id);

create policy "Customers see their requests and specialists see assigned requests" on public.service_requests
  for select to authenticated using (auth.uid() = customer_id or auth.uid() = specialist_id);
create policy "Customers create requests for themselves" on public.service_requests
  for insert to authenticated with check (customer_id = auth.uid());
create policy "Request participants can update requests" on public.service_requests
  for update to authenticated using (auth.uid() = customer_id or auth.uid() = specialist_id)
  with check (auth.uid() = customer_id or auth.uid() = specialist_id);

create policy "Reviews are public" on public.reviews
  for select to anon, authenticated using (true);
create policy "Customers create reviews for themselves" on public.reviews
  for insert to authenticated with check (auth.uid() = customer_id);

insert into public.categories(name,slug,icon,description,sort_order) values
 ('Сантехника','santehnika','🔧','Трубы, смесители и ремонт',1),
 ('Электрика','elektrika','⚡','Проводка, розетки и освещение',2),
 ('Ремонт и строительство','remont-stroitelstvo','🛠️','Отделка, сборка и монтаж',3),
 ('Уборка','uborka','🧹','Дом, квартира и офис',4),
 ('Красота и уход','krasota','💇','Уход, стрижки и макияж',5),
 ('Перевозки','perevozki','🚚','Переезды и доставка',6),
 ('Обучение','obuchenie','📚','Репетиторы и занятия',7),
 ('Другие услуги','drugie-uslugi','✨','Помощь на каждый день',8)
on conflict (slug) do nothing;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles(id, full_name, phone, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    new.phone,
    'customer'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();
