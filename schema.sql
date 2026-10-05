-- BigMoneyParts.com — Phase 1 schema. Run in Supabase SQL Editor.
create extension if not exists "pgcrypto";
create extension if not exists pg_trgm;

create type data_source as enum ('feed', 'vendor_csv', 'manual');
create type partnership_type as enum ('affiliate', 'direct_supplier', 'local_shop');
create type vendor_status as enum ('pending', 'approved', 'rejected');
create type fitment_confidence as enum ('verified', 'universal', 'unknown');

create or replace function set_updated_at() returns trigger as $$
begin new.updated_at = now(); return new; end $$ language plpgsql;

create table brands (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  logo_url text,
  created_at timestamptz not null default now()
);

create table categories (
  id uuid primary key default gen_random_uuid(),
  parent_id uuid references categories(id) on delete set null,
  name text not null,
  slug text not null unique,
  created_at timestamptz not null default now()
);

create table vehicles (
  id uuid primary key default gen_random_uuid(),
  year int not null check (year between 1900 and 2100),
  make text not null,
  model text not null,
  trim text not null default '',
  unique (year, make, model, trim)
);
create index vehicles_ymm_idx on vehicles (make, model, year);

create table vendors (
  id uuid primary key default gen_random_uuid(),
  company_name text not null,
  contact_person text not null,
  email text not null,
  partnership_type partnership_type not null,
  feed_url text,
  catalog_file_path text,
  notes text,
  status vendor_status not null default 'pending',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (feed_url is not null or catalog_file_path is not null)
);
create trigger vendors_updated before update on vendors
  for each row execute function set_updated_at();

create table products (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  slug text not null unique,
  brand_id uuid references brands(id) on delete restrict,
  part_number text not null,
  category_id uuid references categories(id) on delete set null,
  description text,
  base_price numeric(10,2) check (base_price >= 0),
  image_urls text[] not null default '{}',
  source data_source not null,
  needs_review boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),  -- the "last_updated" timestamp
  unique (brand_id, part_number)
);
create index products_category_idx on products (category_id);
create index products_title_trgm on products using gin (title gin_trgm_ops);
create trigger products_updated before update on products
  for each row execute function set_updated_at();

create table fitment (
  product_id uuid not null references products(id) on delete cascade,
  vehicle_id uuid not null references vehicles(id) on delete cascade,
  confidence fitment_confidence not null default 'unknown',  -- only 'verified' may show "guaranteed fit"
  engine_codes text[] not null default '{}',                 -- e.g. {'5.0L Coyote','2.3L EcoBoost'}
  transmissions text[] not null default '{}',                -- e.g. {'manual','automatic'}
  notes text,
  primary key (product_id, vehicle_id)
);
create index fitment_vehicle_idx on fitment (vehicle_id);

create table offers (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references products(id) on delete cascade,
  vendor_id uuid references vendors(id) on delete set null,
  price numeric(10,2) check (price >= 0),
  outbound_url text not null check (outbound_url ~* '^https://'),
  source data_source not null,
  is_active boolean not null default true,
  updated_at timestamptz not null default now(),
  unique (product_id, outbound_url)
);
create index offers_product_idx on offers (product_id);
create trigger offers_updated before update on offers
  for each row execute function set_updated_at();

create table events (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  starts_on date not null,
  ends_on date,
  venue text,
  city text,
  state text,
  motorsport_type text,
  website_url text,
  created_at timestamptz not null default now()
);
create index events_date_idx on events (starts_on);

create table click_tracking (
  id bigint generated always as identity primary key,
  offer_id uuid references offers(id) on delete set null,
  product_id uuid references products(id) on delete set null,
  page_path text,
  referrer text,
  user_agent text,
  clicked_at timestamptz not null default now()
);
create index clicks_offer_idx on click_tracking (offer_id, clicked_at desc);

-- RLS: public reads the catalog; all writes go through the server (service role bypasses RLS).
alter table brands enable row level security;
alter table categories enable row level security;
alter table vehicles enable row level security;
alter table fitment enable row level security;
alter table products enable row level security;
alter table offers enable row level security;
alter table events enable row level security;
alter table vendors enable row level security;
alter table click_tracking enable row level security;

create policy "public read brands" on brands for select using (true);
create policy "public read categories" on categories for select using (true);
create policy "public read vehicles" on vehicles for select using (true);
create policy "public read fitment" on fitment for select using (true);
create policy "public read reviewed products" on products for select using (needs_review = false);
create policy "public read active offers" on offers for select using (is_active = true);
create policy "public read events" on events for select using (true);

insert into storage.buckets (id, name, public) values
  ('vendor-catalogs', 'vendor-catalogs', false),
  ('product-images', 'product-images', true)
on conflict do nothing;
