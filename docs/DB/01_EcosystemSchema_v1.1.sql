-- ##############################################################
-- ##############################################################
-- =========================================================
--  CORE + SATELLITE ECOSYSTEM — SUPABASE / POSTGRESQL 15+
--  - Timezone: UTC
--  - UUID: gen_random_uuid() via pgcrypto
--  - RLS: ENABLED on all business tables + sensitive user tables
--  - Policies split per command where applicable
--  - Functional UNIQUE constraints via UNIQUE INDEX
--  - ORDER: 1) Extensions
--           2) Schemas
--           3) Types (ENUMs)
--           4) TABLES
--           5) INDEXES
--           6) FUNCTIONS
--           7) TRIGGERS
--           8) VIEWS
--           9) POLICIES
--          10) GRANTS
-- =========================================================


-- =====================================================================
-- 1) EXTENSIONS & SESSION
-- =====================================================================
create extension if not exists pgcrypto;
set timezone to 'UTC';


-- =====================================================================
-- 2) SCHEMAS
-- =====================================================================
create schema if not exists sales;


-- =====================================================================
-- 3) TYPES (ENUMs)
-- =====================================================================
do $$
begin
  if not exists (select 1 from pg_type where typname = 'points_tx_type') then
    create type public.points_tx_type as enum ('PURCHASE','REWARD','REDEEM');
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'tenant_role') then
    create type sales.tenant_role as enum ('owner','manager','cashier','stockist','viewer');
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'partner_type') then
    create type sales.partner_type as enum ('customer','supplier','both');
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'product_type') then
    create type sales.product_type as enum ('good','service','bundle','composite');
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'order_status') then
    create type sales.order_status as enum ('draft','confirmed','paid','canceled');
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'transfer_status') then
    create type sales.transfer_status as enum ('draft','approved','in_transit','received','canceled');
  end if;
end $$;


-- =====================================================================
-- 4) TABLES (CREATE TABLE + ENABLE RLS)
--      NOTE: Theo "Y lệnh #1", bổ sung updated_at/deleted_at cho:
--            - sales.authenticity_reports: thêm deleted_at
--            - Các bảng chi tiết: product_units, recipe_components,
--              sales_order_items, purchase_order_items, stock_transfer_items
--            - product_barcodes: bổ sung updated_at để chuẩn hóa
--            - sales.stock_balances giữ nguyên (chỉ cần updated_at)
--            - Các bảng sự kiện bất biến: inventory_movements, daily_sales_summary,
--              tax_ledger, bookings được miễn trừ deleted_at theo chỉ đạo
-- =====================================================================

-- ---------- public
create table if not exists public.profiles (
  id uuid primary key,
  email text,
  created_at timestamptz default now()
);

create table if not exists public.points_ledger (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  points_change integer not null,
  transaction_type public.points_tx_type not null,
  source_app text not null,
  source_transaction_id uuid,
  notes text,
  created_at timestamptz not null default now(),
  created_by uuid
);
alter table public.points_ledger enable row level security;

create table if not exists public.missions (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text,
  reward_points integer not null default 0,
  is_active boolean not null default true,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.missions enable row level security;

create table if not exists public.mission_completions (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  mission_id uuid not null references public.missions(id) on delete cascade,
  completed_at timestamptz not null default now(),
  points_awarded integer not null default 0,
  unique (profile_id, mission_id)
);
alter table public.mission_completions enable row level security;

-- ---------- sales (core)
create table if not exists sales.tenants (
  id uuid primary key default gen_random_uuid(),
  parent_tenant_id uuid references sales.tenants(id) on delete set null,
  name text not null,
  code text unique,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);
alter table sales.tenants enable row level security;

create table if not exists sales.tenant_memberships (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references sales.tenants(id) on delete cascade,
  user_id uuid not null,
  role sales.tenant_role not null default 'viewer',
  invited_by uuid,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  unique (tenant_id, user_id)
);
alter table sales.tenant_memberships enable row level security;

create table if not exists sales.units (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references sales.tenants(id) on delete cascade,
  name text not null,
  abbreviation text,
  is_base boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);
alter table sales.units enable row level security;

create table if not exists sales.warehouses (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references sales.tenants(id) on delete cascade,
  name text not null,
  code text,
  address text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);
alter table sales.warehouses enable row level security;

create table if not exists sales.partners (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references sales.tenants(id) on delete cascade,
  name text not null,
  type sales.partner_type not null default 'both',
  phone text,
  email text,
  address text,
  tax_code text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);
alter table sales.partners enable row level security;

-- product catalog
create table if not exists sales.product_roots (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references sales.tenants(id) on delete cascade,
  name text not null,
  base_unit_id uuid references sales.units(id),
  product_type sales.product_type not null default 'good',
  brand text,
  category text,
  status text not null default 'active',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);
alter table sales.product_roots enable row level security;

create table if not exists sales.product_variants (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references sales.tenants(id) on delete cascade,
  product_id uuid not null references sales.product_roots(id) on delete cascade,
  sku text,
  barcode text,
  attributes jsonb not null default '{}'::jsonb,
  unit_price numeric(18,4) not null default 0,
  cost_price numeric(18,4),
  tax_rate numeric(5,2) default 0,
  track_inventory boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  unique (tenant_id, sku)
);
alter table sales.product_variants enable row level security;

create table if not exists sales.product_barcodes (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references sales.tenants(id) on delete cascade,
  variant_id uuid not null references sales.product_variants(id) on delete cascade,
  barcode text not null,
  is_primary boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  unique (variant_id, barcode)
);
alter table sales.product_barcodes enable row level security;

create table if not exists sales.product_units (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references sales.tenants(id) on delete cascade,
  variant_id uuid not null references sales.product_variants(id) on delete cascade,
  unit_id uuid not null references sales.units(id),
  factor numeric(18,6) not null check (factor > 0),
  is_default boolean not null default false,
  is_default_purchase_unit boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  unique (variant_id, unit_id)
);
alter table sales.product_units enable row level security;

-- resources
create table if not exists sales.resources (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references sales.tenants(id) on delete cascade,
  warehouse_id uuid references sales.warehouses(id),
  name text not null,
  type text,
  status text not null default 'available',
  metadata jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);
alter table sales.resources enable row level security;

-- orders & items
create table if not exists sales.sales_orders (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references sales.tenants(id) on delete cascade,
  order_no text not null,
  partner_id uuid references sales.partners(id),
  warehouse_id uuid not null references sales.warehouses(id),
  resource_id uuid references sales.resources(id),
  location_id uuid references sales.resources(id),
  status sales.order_status not null default 'draft',
  created_by uuid,
  subtotal numeric(18,4) not null default 0,
  discount_total numeric(18,4) not null default 0,
  tax_total numeric(18,4) not null default 0,
  grand_total numeric(18,4) not null default 0,
  idempotency_key text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  unique (tenant_id, order_no),
  unique (tenant_id, idempotency_key)
);
alter table sales.sales_orders enable row level security;

create table if not exists sales.sales_order_items (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references sales.tenants(id) on delete cascade,
  order_id uuid not null references sales.sales_orders(id) on delete cascade,
  variant_id uuid not null references sales.product_variants(id),
  qty numeric(18,3) not null check (qty > 0),
  unit_price numeric(18,4) not null check (unit_price >= 0),
  discount_amount numeric(18,4) not null default 0,
  tax_rate numeric(5,2) not null default 0,
  line_total numeric(18,4) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);
alter table sales.sales_order_items enable row level security;

create table if not exists sales.purchase_orders (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references sales.tenants(id) on delete cascade,
  order_no text not null,
  partner_id uuid references sales.partners(id),
  warehouse_id uuid not null references sales.warehouses(id),
  status sales.order_status not null default 'draft',
  created_by uuid,
  subtotal numeric(18,4) not null default 0,
  discount_total numeric(18,4) not null default 0,
  tax_total numeric(18,4) not null default 0,
  grand_total numeric(18,4) not null default 0,
  idempotency_key text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  unique (tenant_id, order_no),
  unique (tenant_id, idempotency_key)
);
alter table sales.purchase_orders enable row level security;

create table if not exists sales.purchase_order_items (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references sales.tenants(id) on delete cascade,
  order_id uuid not null references sales.purchase_orders(id) on delete cascade,
  variant_id uuid not null references sales.product_variants(id),
  qty numeric(18,3) not null check (qty > 0),
  unit_cost numeric(18,4) not null check (unit_cost >= 0),
  discount_amount numeric(18,4) not null default 0,
  tax_rate numeric(5,2) not null default 0,
  line_total numeric(18,4) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);
alter table sales.purchase_order_items enable row level security;

-- bookings (event-like -> no deleted_at by design)
create table if not exists sales.bookings (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references sales.tenants(id) on delete cascade,
  order_id uuid not null references sales.sales_orders(id) on delete cascade,
  resource_id uuid not null references sales.resources(id),
  variant_id uuid not null references sales.product_variants(id),
  start_time timestamptz not null default now(),
  end_time timestamptz,
  duration_minutes numeric,
  rate_per_hour numeric(18,4) not null,
  line_total numeric(18,4) not null default 0,
  created_at timestamptz not null default now()
);
alter table sales.bookings enable row level security;

-- inventory
create table if not exists sales.stock_transfers (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references sales.tenants(id) on delete cascade,
  transfer_no text not null,
  from_warehouse_id uuid not null references sales.warehouses(id),
  to_warehouse_id   uuid not null references sales.warehouses(id),
  status sales.transfer_status not null default 'draft',
  created_by uuid,
  approved_by uuid,
  received_by uuid,
  idempotency_key text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  unique (tenant_id, transfer_no),
  unique (tenant_id, idempotency_key)
);
alter table sales.stock_transfers enable row level security;

create table if not exists sales.stock_transfer_items (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references sales.tenants(id) on delete cascade,
  transfer_id uuid not null references sales.stock_transfers(id) on delete cascade,
  variant_id uuid not null references sales.product_variants(id),
  qty numeric(18,3) not null check (qty > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);
alter table sales.stock_transfer_items enable row level security;

create table if not exists sales.stock_balances (
  tenant_id uuid not null references sales.tenants(id) on delete cascade,
  warehouse_id uuid not null references sales.warehouses(id) on delete cascade,
  variant_id uuid not null references sales.product_variants(id) on delete cascade,
  qty numeric(18,3) not null default 0,
  updated_at timestamptz not null default now(),
  primary key (tenant_id, warehouse_id, variant_id)
);
alter table sales.stock_balances enable row level security;

create table if not exists sales.inventory_movements (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references sales.tenants(id) on delete cascade,
  warehouse_id uuid not null references sales.warehouses(id) on delete cascade,
  variant_id uuid not null references sales.product_variants(id) on delete cascade,
  doc_type text not null,
  doc_id uuid,
  direction text not null check (direction in ('in','out')),
  quantity numeric(18,3) not null check (quantity > 0),
  created_at timestamptz not null default now(),
  unique(tenant_id, doc_type, doc_id, variant_id, direction)
);
alter table sales.inventory_movements enable row level security;

-- recipes
create table if not exists sales.recipes (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references sales.tenants(id) on delete cascade,
  finished_variant_id uuid not null references sales.product_variants(id) on delete cascade,
  yield_qty numeric(18,3) not null default 1,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);
alter table sales.recipes enable row level security;

create table if not exists sales.recipe_components (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references sales.tenants(id) on delete cascade,
  recipe_id uuid not null references sales.recipes(id) on delete cascade,
  ingredient_variant_id uuid not null references sales.product_variants(id) on delete restrict,
  qty numeric(18,3) not null check (qty > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);
alter table sales.recipe_components enable row level security;

-- reviews & authenticity
create table if not exists sales.product_reviews (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references sales.tenants(id) on delete cascade,
  variant_id uuid not null references sales.product_variants(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  rating int not null check (rating between 1 and 5),
  comment text,
  images jsonb default '[]'::jsonb,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);
alter table sales.product_reviews enable row level security;

create table if not exists sales.authenticity_reports (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references sales.tenants(id) on delete cascade,
  variant_id uuid not null references sales.product_variants(id) on delete cascade,
  reported_by uuid,
  details jsonb not null default '{}'::jsonb,
  is_verified boolean not null default false,
  verified_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);
alter table sales.authenticity_reports enable row level security;

-- tax & summary (event-like)
create table if not exists sales.tax_ledger (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references sales.tenants(id) on delete cascade,
  posting_date date not null,
  doc_type text not null,
  doc_id uuid not null,
  tax_base numeric(18,4) not null default 0,
  tax_amount numeric(18,4) not null default 0,
  created_at timestamptz not null default now()
);
alter table sales.tax_ledger enable row level security;

create table if not exists sales.daily_sales_summary (
  tenant_id uuid not null references sales.tenants(id) on delete cascade,
  business_date date not null,
  orders_count integer not null default 0,
  gross_sales numeric(18,4) not null default 0,
  discounts_total numeric(18,4) not null default 0,
  taxes_total numeric(18,4) not null default 0,
  net_sales numeric(18,4) not null default 0,
  updated_at timestamptz not null default now(),
  primary key (tenant_id, business_date)
);
alter table sales.daily_sales_summary enable row level security;

-- expenses
create table if not exists sales.expenses (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references sales.tenants(id) on delete cascade,
  spend_date date not null default (now()::date),
  category text not null,
  amount numeric(18,4) not null check (amount >= 0),
  partner_id uuid references sales.partners(id),
  note text,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);
alter table sales.expenses enable row level security;


-- =====================================================================
-- 5) INDEXES (including functional UNIQUE)
-- =====================================================================
create unique index if not exists uq_units_tenant_lower_name
  on sales.units (tenant_id, (lower(name)));

create unique index if not exists uq_warehouses_tenant_lower_name
  on sales.warehouses (tenant_id, (lower(name)));

create unique index if not exists uq_product_roots_tenant_lower_name
  on sales.product_roots (tenant_id, (lower(name)));

create index if not exists ix_variants_tenant_barcode
  on sales.product_variants(tenant_id, barcode);

create index if not exists ix_barcodes_tenant_barcode
  on sales.product_barcodes(tenant_id, barcode);

create index if not exists ix_stock_balances_variant
  on sales.stock_balances(tenant_id, variant_id);

create index if not exists ix_inv_move_tenant_doc
  on sales.inventory_movements(tenant_id, doc_type, doc_id);

create index if not exists ix_sales_items_order
  on sales.sales_order_items(order_id);

create index if not exists ix_purchase_items_order
  on sales.purchase_order_items(order_id);

create index if not exists ix_sales_orders_tenant_status_created
  on sales.sales_orders(tenant_id, status, created_at desc);

create index if not exists ix_purchase_orders_tenant_status_created
  on sales.purchase_orders(tenant_id, status, created_at desc);


-- =====================================================================
-- 6) FUNCTIONS
-- =====================================================================

-- public helpers
create or replace function public.is_self(p_profile uuid)
returns boolean
language sql
security definer
set search_path = public
as $$
  select auth.uid() = p_profile
$$;

create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- sales helpers
create or replace function sales.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- missions: award points
create or replace function public.award_points_on_mission_completion()
returns trigger language plpgsql as $$
declare v_points int;
begin
  select reward_points into v_points from public.missions where id = new.mission_id;
  new.points_awarded := coalesce(v_points,0);

  insert into public.points_ledger(profile_id, points_change, transaction_type, source_app, source_transaction_id, notes, created_by)
  values (new.profile_id, new.points_awarded, 'REWARD', 'missions', new.id, 'Mission reward', auth.uid());
  return new;
end $$;

-- bookings
create or replace function sales.finalize_booking()
returns trigger language plpgsql as $$
declare v_minutes numeric;
begin
  if new.end_time is not null and (old.end_time is distinct from new.end_time) then
    v_minutes := extract(epoch from (new.end_time - new.start_time)) / 60.0;
    new.duration_minutes := round(v_minutes, 2);
    new.line_total := round((new.rate_per_hour * (new.duration_minutes/60.0))::numeric, 4);
  end if;
  return new;
end $$;

-- inventory balances apply
create or replace function sales.apply_inventory_movement()
returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    insert into sales.stock_balances as sb(tenant_id, warehouse_id, variant_id, qty, updated_at)
    values (
      new.tenant_id, new.warehouse_id, new.variant_id,
      case when new.direction='in' then new.quantity else -new.quantity end,
      now()
    )
    on conflict (tenant_id, warehouse_id, variant_id)
    do update set qty = sb.qty + excluded.qty,
                 updated_at = now();
  end if;
  return new;
end $$;

-- sales orders aggregation & tax
create or replace function sales.after_sales_order_change()
returns trigger language plpgsql as $$
declare
  v_date date;
  v_gross numeric(18,4);
  v_disc numeric(18,4);
  v_tax  numeric(18,4);
  v_net  numeric(18,4);
begin
  if (tg_op = 'INSERT') or (tg_op = 'UPDATE') then
    if new.status in ('confirmed','paid') then
      execute $q$
        select coalesce(sum(i.qty * i.unit_price),0),
               coalesce(sum(i.discount_amount),0),
               coalesce(sum(round((i.qty * i.unit_price - i.discount_amount) * (i.tax_rate/100.0), 4)),0)
        from sales.sales_order_items i
        where i.order_id = $1
      $q$ into v_gross, v_disc, v_tax using new.id;

      v_net  := v_gross - v_disc + v_tax;
      v_date := (new.created_at at time zone 'utc')::date;

      execute $q$
        insert into sales.daily_sales_summary as s
          (tenant_id, business_date, orders_count, gross_sales, discounts_total, taxes_total, net_sales, updated_at)
        values ($1, $2, 1, $3, $4, $5, $6, now())
        on conflict (tenant_id, business_date) do update
          set orders_count    = s.orders_count + 1,
              gross_sales     = s.gross_sales + excluded.gross_sales,
              discounts_total = s.discounts_total + excluded.discounts_total,
              taxes_total     = s.taxes_total + excluded.taxes_total,
              net_sales       = s.net_sales + excluded.net_sales,
              updated_at      = now()
      $q$ using new.tenant_id, v_date, v_gross, v_disc, v_tax, v_net;

      execute $q$
        insert into sales.tax_ledger(tenant_id, posting_date, doc_type, doc_id, tax_base, tax_amount)
        values ($1, $2, 'sale', $3, $4, $5)
        on conflict do nothing
      $q$ using new.tenant_id, v_date, new.id, (v_gross - v_disc), v_tax;

      if new.status = 'confirmed' then
        execute $q$
          insert into sales.inventory_movements(tenant_id, warehouse_id, variant_id, doc_type, doc_id, direction, quantity)
          select $1, $2, i.variant_id, 'sale', $3, 'out', i.qty
          from sales.sales_order_items i
          where i.order_id = $3
          on conflict do nothing
        $q$ using new.tenant_id, new.warehouse_id, new.id;
      end if;
    end if;
  end if;
  return new;
end $$;

-- purchase orders tax & stock in
create or replace function sales.after_purchase_order_change()
returns trigger language plpgsql as $$
declare
  v_date date;
  v_gross numeric(18,4);
  v_disc numeric(18,4);
  v_tax  numeric(18,4);
begin
  if (tg_op = 'INSERT') or (tg_op = 'UPDATE') then
    if new.status in ('confirmed','paid') then
      execute $q$
        select coalesce(sum(i.qty * i.unit_cost),0),
               coalesce(sum(i.discount_amount),0),
               coalesce(sum(round((i.qty * i.unit_cost - i.discount_amount) * (i.tax_rate/100.0), 4)),0)
        from sales.purchase_order_items i
        where i.order_id = $1
      $q$ into v_gross, v_disc, v_tax using new.id;

      v_date := (new.created_at at time zone 'utc')::date;

      execute $q$
        insert into sales.tax_ledger(tenant_id, posting_date, doc_type, doc_id, tax_base, tax_amount)
        values ($1, $2, 'purchase', $3, $4, $5)
        on conflict do nothing
      $q$ using new.tenant_id, v_date, new.id, (v_gross - v_disc), v_tax;

      if new.status = 'confirmed' then
        execute $q$
          insert into sales.inventory_movements(tenant_id, warehouse_id, variant_id, doc_type, doc_id, direction, quantity)
          select $1, $2, i.variant_id, 'purchase', $3, 'in', i.qty
          from sales.purchase_order_items i
          where i.order_id = $3
          on conflict do nothing
        $q$ using new.tenant_id, new.warehouse_id, new.id;
      end if;
    end if;
  end if;
  return new;
end $$;

-- stock transfer moves
create or replace function sales.after_stock_transfer_change()
returns trigger language plpgsql as $$
begin
  if (tg_op = 'UPDATE') then
    if new.status = 'approved' and (old.status is distinct from 'approved') then
      execute $q$
        insert into sales.inventory_movements(tenant_id, warehouse_id, variant_id, doc_type, doc_id, direction, quantity)
        select $1, $2, i.variant_id, 'transfer', $3, 'out', i.qty
        from sales.stock_transfer_items i
        where i.transfer_id = $3
        on conflict do nothing
      $q$ using new.tenant_id, new.from_warehouse_id, new.id;
    end if;

    if new.status = 'received' and (old.status is distinct from 'received') then
      execute $q$
        insert into sales.inventory_movements(tenant_id, warehouse_id, variant_id, doc_type, doc_id, direction, quantity)
        select $1, $2, i.variant_id, 'transfer', $3, 'in', i.qty
        from sales.stock_transfer_items i
        where i.transfer_id = $3
        on conflict do nothing
      $q$ using new.tenant_id, new.to_warehouse_id, new.id;
    end if;
  end if;
  return new;
end $$;


-- =====================================================================
-- 7) TRIGGERS
-- =====================================================================

-- public.missions
drop trigger if exists trg_missions_touch_updated on public.missions;
create trigger trg_missions_touch_updated
before update on public.missions
for each row execute function public.touch_updated_at();

-- public.mission_completions (Y lệnh #3: tên DROP = tên CREATE)
drop trigger if exists trg_award_points_on_mission_completions on public.mission_completions;
create trigger trg_award_points_on_mission_completions
after insert on public.mission_completions
for each row execute function public.award_points_on_mission_completion();

-- sales.tenants
drop trigger if exists trg_tenants_touch_updated on sales.tenants;
create trigger trg_tenants_touch_updated
before update on sales.tenants
for each row execute function sales.touch_updated_at();

-- sales.tenant_memberships
drop trigger if exists trg_tenant_memberships_touch_updated on sales.tenant_memberships;
create trigger trg_tenant_memberships_touch_updated
before update on sales.tenant_memberships
for each row execute function sales.touch_updated_at();

-- sales.units
drop trigger if exists trg_units_touch_updated on sales.units;
create trigger trg_units_touch_updated
before update on sales.units
for each row execute function sales.touch_updated_at();

-- sales.warehouses
drop trigger if exists trg_warehouses_touch_updated on sales.warehouses;
create trigger trg_warehouses_touch_updated
before update on sales.warehouses
for each row execute function sales.touch_updated_at();

-- sales.partners
drop trigger if exists trg_partners_touch_updated on sales.partners;
create trigger trg_partners_touch_updated
before update on sales.partners
for each row execute function sales.touch_updated_at();

-- sales.product_roots
drop trigger if exists trg_product_roots_touch_updated on sales.product_roots;
create trigger trg_product_roots_touch_updated
before update on sales.product_roots
for each row execute function sales.touch_updated_at();

-- sales.product_variants
drop trigger if exists trg_product_variants_touch_updated on sales.product_variants;
create trigger trg_product_variants_touch_updated
before update on sales.product_variants
for each row execute function sales.touch_updated_at();

-- sales.product_barcodes
drop trigger if exists trg_product_barcodes_touch_updated on sales.product_barcodes;
create trigger trg_product_barcodes_touch_updated
before update on sales.product_barcodes
for each row execute function sales.touch_updated_at();

-- sales.product_units
drop trigger if exists trg_product_units_touch_updated on sales.product_units;
create trigger trg_product_units_touch_updated
before update on sales.product_units
for each row execute function sales.touch_updated_at();

-- sales.resources
drop trigger if exists trg_resources_touch_updated on sales.resources;
create trigger trg_resources_touch_updated
before update on sales.resources
for each row execute function sales.touch_updated_at();

-- sales.sales_orders
drop trigger if exists trg_sales_orders_touch_updated on sales.sales_orders;
create trigger trg_sales_orders_touch_updated
before update on sales.sales_orders
for each row execute function sales.touch_updated_at();

drop trigger if exists trg_after_sales_order_change on sales.sales_orders;
create trigger trg_after_sales_order_change
after insert or update on sales.sales_orders
for each row execute function sales.after_sales_order_change();

-- sales.sales_order_items
drop trigger if exists trg_sales_order_items_touch_updated on sales.sales_order_items;
create trigger trg_sales_order_items_touch_updated
before update on sales.sales_order_items
for each row execute function sales.touch_updated_at();

-- sales.purchase_orders
drop trigger if exists trg_purchase_orders_touch_updated on sales.purchase_orders;
create trigger trg_purchase_orders_touch_updated
before update on sales.purchase_orders
for each row execute function sales.touch_updated_at();

drop trigger if exists trg_after_purchase_order_change on sales.purchase_orders;
create trigger trg_after_purchase_order_change
after insert or update on sales.purchase_orders
for each row execute function sales.after_purchase_order_change();

-- sales.purchase_order_items
drop trigger if exists trg_purchase_order_items_touch_updated on sales.purchase_order_items;
create trigger trg_purchase_order_items_touch_updated
before update on sales.purchase_order_items
for each row execute function sales.touch_updated_at();

-- sales.bookings (event compute)
drop trigger if exists trg_finalize_booking on sales.bookings;
create trigger trg_finalize_booking
before update on sales.bookings
for each row execute function sales.finalize_booking();

-- sales.stock_transfers
drop trigger if exists trg_stock_transfers_touch_updated on sales.stock_transfers;
create trigger trg_stock_transfers_touch_updated
before update on sales.stock_transfers
for each row execute function sales.touch_updated_at();

drop trigger if exists trg_after_stock_transfer_change on sales.stock_transfers;
create trigger trg_after_stock_transfer_change
after update on sales.stock_transfers
for each row execute function sales.after_stock_transfer_change();

-- sales.stock_transfer_items
drop trigger if exists trg_stock_transfer_items_touch_updated on sales.stock_transfer_items;
create trigger trg_stock_transfer_items_touch_updated
before update on sales.stock_transfer_items
for each row execute function sales.touch_updated_at();

-- sales.inventory_movements (apply to balances)
drop trigger if exists trg_apply_inventory_movement on sales.inventory_movements;
create trigger trg_apply_inventory_movement
after insert on sales.inventory_movements
for each row execute function sales.apply_inventory_movement();

-- sales.recipes
drop trigger if exists trg_recipes_touch_updated on sales.recipes;
create trigger trg_recipes_touch_updated
before update on sales.recipes
for each row execute function sales.touch_updated_at();

-- sales.recipe_components
drop trigger if exists trg_recipe_components_touch_updated on sales.recipe_components;
create trigger trg_recipe_components_touch_updated
before update on sales.recipe_components
for each row execute function sales.touch_updated_at();

-- sales.product_reviews
drop trigger if exists trg_reviews_touch_updated on sales.product_reviews;
create trigger trg_reviews_touch_updated
before update on sales.product_reviews
for each row execute function sales.touch_updated_at();

-- sales.authenticity_reports
drop trigger if exists trg_auth_reports_touch_updated on sales.authenticity_reports;
create trigger trg_auth_reports_touch_updated
before update on sales.authenticity_reports
for each row execute function sales.touch_updated_at();

-- sales.expenses
drop trigger if exists trg_expenses_touch_updated on sales.expenses;
create trigger trg_expenses_touch_updated
before update on sales.expenses
for each row execute function sales.touch_updated_at();


-- =====================================================================
-- 8) VIEWS
-- =====================================================================
create or replace view sales.service_locations as
  select id, tenant_id, warehouse_id, name, type, status, metadata, created_at, updated_at, deleted_at
  from sales.resources
  where deleted_at is null;

create or replace view sales.service_usages as
  select b.id, b.tenant_id, b.order_id, b.resource_id as location_id, b.variant_id,
         b.start_time, b.end_time, b.duration_minutes, b.rate_per_hour, b.line_total, b.created_at
  from sales.bookings b;


-- =====================================================================
-- 9) POLICIES (one action per policy; no semicolons inside expressions)
-- =====================================================================

-- public.points_ledger
drop policy if exists p_points_ledger_select_self on public.points_ledger;
create policy p_points_ledger_select_self on public.points_ledger
for select to authenticated
using (public.is_self(profile_id));

drop policy if exists p_points_ledger_all_service on public.points_ledger;
create policy p_points_ledger_all_service on public.points_ledger
for all to service_role
using (true) with check (true);

-- public.missions
drop policy if exists p_missions_select_all on public.missions;
create policy p_missions_select_all on public.missions
for select to authenticated
using (true);

drop policy if exists p_missions_all_service on public.missions;
create policy p_missions_all_service on public.missions
for all to service_role
using (true) with check (true);

-- public.mission_completions
drop policy if exists p_mission_complete_select_self on public.mission_completions;
create policy p_mission_complete_select_self on public.mission_completions
for select to authenticated
using (public.is_self(profile_id));

drop policy if exists p_mission_complete_insert_self on public.mission_completions;
create policy p_mission_complete_insert_self on public.mission_completions
for insert to authenticated
with check (public.is_self(profile_id));

drop policy if exists p_mission_complete_all_service on public.mission_completions;
create policy p_mission_complete_all_service on public.mission_completions
for all to service_role
using (true) with check (true);

-- sales.tenants
drop policy if exists p_tenants_select_member on sales.tenants;
create policy p_tenants_select_member on sales.tenants
for select to authenticated
using (
  exists (
    select 1 from sales.tenant_memberships m
    where m.tenant_id = id
      and m.user_id = auth.uid()
      and m.deleted_at is null
  )
);

drop policy if exists p_tenants_all_service on sales.tenants;
create policy p_tenants_all_service on sales.tenants
for all to service_role
using (true) with check (true);

-- sales.tenant_memberships
drop policy if exists p_memberships_select_member on sales.tenant_memberships;
create policy p_memberships_select_member on sales.tenant_memberships
for select to authenticated
using (
  exists (
    select 1 from sales.tenant_memberships m
    where m.tenant_id = tenant_id
      and m.user_id = auth.uid()
      and m.deleted_at is null
  )
);

drop policy if exists p_memberships_insert on sales.tenant_memberships;
create policy p_memberships_insert on sales.tenant_memberships
for insert to authenticated
with check (
  exists (
    select 1 from sales.tenant_memberships m
    where m.tenant_id = tenant_id
      and m.user_id = auth.uid()
      and m.role = any (array['owner','manager']::sales.tenant_role[])
      and m.deleted_at is null
  )
);

drop policy if exists p_memberships_update on sales.tenant_memberships;
create policy p_memberships_update on sales.tenant_memberships
for update to authenticated
using (
  exists (
    select 1 from sales.tenant_memberships m
    where m.tenant_id = tenant_id
      and m.user_id = auth.uid()
      and m.role = any (array['owner','manager']::sales.tenant_role[])
      and m.deleted_at is null
  )
)
with check (
  exists (
    select 1 from sales.tenant_memberships m
    where m.tenant_id = tenant_id
      and m.user_id = auth.uid()
      and m.role = any (array['owner','manager']::sales.tenant_role[])
      and m.deleted_at is null
  )
);

drop policy if exists p_memberships_delete on sales.tenant_memberships;
create policy p_memberships_delete on sales.tenant_memberships
for delete to authenticated
using (
  exists (
    select 1 from sales.tenant_memberships m
    where m.tenant_id = tenant_id
      and m.user_id = auth.uid()
      and m.role = any (array['owner','manager']::sales.tenant_role[])
      and m.deleted_at is null
  )
);

drop policy if exists p_memberships_all_service on sales.tenant_memberships;
create policy p_memberships_all_service on sales.tenant_memberships
for all to service_role
using (true) with check (true);

-- sales.units
drop policy if exists p_units_all on sales.units;
create policy p_units_all on sales.units
for all to authenticated
using (
  exists (select 1 from sales.tenant_memberships m
          where m.tenant_id = tenant_id and m.user_id = auth.uid() and m.deleted_at is null)
)
with check (
  exists (select 1 from sales.tenant_memberships m
          where m.tenant_id = tenant_id and m.user_id = auth.uid()
            and m.role = any (array['owner','manager','stockist']::sales.tenant_role[])
            and m.deleted_at is null)
);

drop policy if exists p_units_service on sales.units;
create policy p_units_service on sales.units
for all to service_role
using (true) with check (true);

-- sales.warehouses
drop policy if exists p_warehouses_all on sales.warehouses;
create policy p_warehouses_all on sales.warehouses
for all to authenticated
using (
  exists (select 1 from sales.tenant_memberships m
          where m.tenant_id = tenant_id and m.user_id = auth.uid() and m.deleted_at is null)
)
with check (
  exists (select 1 from sales.tenant_memberships m
          where m.tenant_id = tenant_id and m.user_id = auth.uid()
            and m.role = any (array['owner','manager','stockist']::sales.tenant_role[])
            and m.deleted_at is null)
);

drop policy if exists p_warehouses_service on sales.warehouses;
create policy p_warehouses_service on sales.warehouses
for all to service_role
using (true) with check (true);

-- sales.partners
drop policy if exists p_partners_select on sales.partners;
create policy p_partners_select on sales.partners
for select to authenticated
using (
  exists (select 1 from sales.tenant_memberships m
          where m.tenant_id = tenant_id and m.user_id = auth.uid() and m.deleted_at is null)
);

drop policy if exists p_partners_insert on sales.partners;
create policy p_partners_insert on sales.partners
for insert to authenticated
with check (
  exists (select 1 from sales.tenant_memberships m
          where m.tenant_id = tenant_id and m.user_id = auth.uid()
            and m.role = any (array['owner','manager']::sales.tenant_role[])
            and m.deleted_at is null)
);

drop policy if exists p_partners_update on sales.partners;
create policy p_partners_update on sales.partners
for update to authenticated
using (
  exists (select 1 from sales.tenant_memberships m
          where m.tenant_id = tenant_id and m.user_id = auth.uid() and m.deleted_at is null)
)
with check (
  exists (select 1 from sales.tenant_memberships m
          where m.tenant_id = tenant_id and m.user_id = auth.uid()
            and m.role = any (array['owner','manager']::sales.tenant_role[])
            and m.deleted_at is null)
);

drop policy if exists p_partners_delete on sales.partners;
create policy p_partners_delete on sales.partners
for delete to authenticated
using (
  exists (select 1 from sales.tenant_memberships m
          where m.tenant_id = tenant_id and m.user_id = auth.uid()
            and m.role = any (array['owner','manager']::sales.tenant_role[])
            and m.deleted_at is null)
);

drop policy if exists p_partners_service on sales.partners;
create policy p_partners_service on sales.partners
for all to service_role
using (true) with check (true);

-- product catalog
drop policy if exists p_products_select on sales.product_roots;
create policy p_products_select on sales.product_roots
for select to authenticated
using (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid() and m.deleted_at is null)
);

drop policy if exists p_products_insert on sales.product_roots;
create policy p_products_insert on sales.product_roots
for insert to authenticated
with check (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid()
           and m.role = any (array['owner','manager','stockist']::sales.tenant_role[]) and m.deleted_at is null)
);

drop policy if exists p_products_update on sales.product_roots;
create policy p_products_update on sales.product_roots
for update to authenticated
using (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid() and m.deleted_at is null)
)
with check (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid()
           and m.role = any (array['owner','manager','stockist']::sales.tenant_role[]) and m.deleted_at is null)
);

drop policy if exists p_products_delete on sales.product_roots;
create policy p_products_delete on sales.product_roots
for delete to authenticated
using (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid()
           and m.role = any (array['owner','manager','stockist']::sales.tenant_role[]) and m.deleted_at is null)
);

drop policy if exists p_products_all_service on sales.product_roots;
create policy p_products_all_service on sales.product_roots
for all to service_role
using (true) with check (true);

drop policy if exists p_variants_select on sales.product_variants;
create policy p_variants_select on sales.product_variants
for select to authenticated
using (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid() and m.deleted_at is null)
);

drop policy if exists p_variants_insert on sales.product_variants;
create policy p_variants_insert on sales.product_variants
for insert to authenticated
with check (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid()
           and m.role = any (array['owner','manager','stockist']::sales.tenant_role[]) and m.deleted_at is null)
);

drop policy if exists p_variants_update on sales.product_variants;
create policy p_variants_update on sales.product_variants
for update to authenticated
using (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid() and m.deleted_at is null)
)
with check (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid()
           and m.role = any (array['owner','manager','stockist']::sales.tenant_role[]) and m.deleted_at is null)
);

drop policy if exists p_variants_delete on sales.product_variants;
create policy p_variants_delete on sales.product_variants
for delete to authenticated
using (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid()
           and m.role = any (array['owner','manager','stockist']::sales.tenant_role[]) and m.deleted_at is null)
);

drop policy if exists p_variants_all_service on sales.product_variants;
create policy p_variants_all_service on sales.product_variants
for all to service_role
using (true) with check (true);

drop policy if exists p_barcodes_select on sales.product_barcodes;
create policy p_barcodes_select on sales.product_barcodes
for select to authenticated
using (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid() and m.deleted_at is null)
);

drop policy if exists p_barcodes_insert on sales.product_barcodes;
create policy p_barcodes_insert on sales.product_barcodes
for insert to authenticated
with check (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid()
           and m.role = any (array['owner','manager','stockist']::sales.tenant_role[]) and m.deleted_at is null)
);

drop policy if exists p_barcodes_update on sales.product_barcodes;
create policy p_barcodes_update on sales.product_barcodes
for update to authenticated
using (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid() and m.deleted_at is null)
)
with check (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid()
           and m.role = any (array['owner','manager','stockist']::sales.tenant_role[]) and m.deleted_at is null)
);

drop policy if exists p_barcodes_delete on sales.product_barcodes;
create policy p_barcodes_delete on sales.product_barcodes
for delete to authenticated
using (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid()
           and m.role = any (array['owner','manager','stockist']::sales.tenant_role[]) and m.deleted_at is null)
);

drop policy if exists p_barcodes_all_service on sales.product_barcodes;
create policy p_barcodes_all_service on sales.product_barcodes
for all to service_role
using (true) with check (true);

drop policy if exists p_punits_select on sales.product_units;
create policy p_punits_select on sales.product_units
for select to authenticated
using (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid() and m.deleted_at is null)
);

drop policy if exists p_punits_insert on sales.product_units;
create policy p_punits_insert on sales.product_units
for insert to authenticated
with check (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid()
           and m.role = any (array['owner','manager','stockist']::sales.tenant_role[]) and m.deleted_at is null)
);

drop policy if exists p_punits_update on sales.product_units;
create policy p_punits_update on sales.product_units
for update to authenticated
using (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid() and m.deleted_at is null)
)
with check (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid()
           and m.role = any (array['owner','manager','stockist']::sales.tenant_role[]) and m.deleted_at is null)
);

drop policy if exists p_punits_delete on sales.product_units;
create policy p_punits_delete on sales.product_units
for delete to authenticated
using (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid()
           and m.role = any (array['owner','manager','stockist']::sales.tenant_role[]) and m.deleted_at is null)
);

drop policy if exists p_punits_all_service on sales.product_units;
create policy p_punits_all_service on sales.product_units
for all to service_role
using (true) with check (true);

-- resources & bookings
drop policy if exists p_resources_all on sales.resources;
create policy p_resources_all on sales.resources
for all to authenticated
using (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid() and m.deleted_at is null)
)
with check (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid()
           and m.role = any (array['owner','manager']::sales.tenant_role[]) and m.deleted_at is null)
);

drop policy if exists p_resources_service on sales.resources;
create policy p_resources_service on sales.resources
for all to service_role
using (true) with check (true);

drop policy if exists p_bookings_all on sales.bookings;
create policy p_bookings_all on sales.bookings
for all to authenticated
using (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid() and m.deleted_at is null)
)
with check (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid()
           and m.role = any (array['owner','manager','cashier']::sales.tenant_role[]) and m.deleted_at is null)
);

drop policy if exists p_bookings_service on sales.bookings;
create policy p_bookings_service on sales.bookings
for all to service_role
using (true) with check (true);

-- inventory
drop policy if exists p_transfers_select on sales.stock_transfers;
create policy p_transfers_select on sales.stock_transfers
for select to authenticated
using (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid() and m.deleted_at is null)
);

drop policy if exists p_transfers_insert on sales.stock_transfers;
create policy p_transfers_insert on sales.stock_transfers
for insert to authenticated
with check (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid()
           and m.role = any (array['owner','manager','stockist']::sales.tenant_role[]) and m.deleted_at is null)
);

drop policy if exists p_transfers_update on sales.stock_transfers;
create policy p_transfers_update on sales.stock_transfers
for update to authenticated
using (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid() and m.deleted_at is null)
)
with check (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid()
           and m.role = any (array['owner','manager','stockist']::sales.tenant_role[]) and m.deleted_at is null)
);

drop policy if exists p_transfers_service on sales.stock_transfers;
create policy p_transfers_service on sales.stock_transfers
for all to service_role
using (true) with check (true);

drop policy if exists p_transfer_items_all on sales.stock_transfer_items;
create policy p_transfer_items_all on sales.stock_transfer_items
for all to authenticated
using (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid() and m.deleted_at is null)
)
with check (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid()
           and m.role = any (array['owner','manager','stockist']::sales.tenant_role[]) and m.deleted_at is null)
);

drop policy if exists p_transfer_items_service on sales.stock_transfer_items;
create policy p_transfer_items_service on sales.stock_transfer_items
for all to service_role
using (true) with check (true);

drop policy if exists p_stock_select on sales.stock_balances;
create policy p_stock_select on sales.stock_balances
for select to authenticated
using (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid() and m.deleted_at is null)
);

drop policy if exists p_inv_movements_all on sales.inventory_movements;
create policy p_inv_movements_all on sales.inventory_movements
for all to authenticated
using (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid() and m.deleted_at is null)
)
with check (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid()
           and m.role = any (array['owner','manager','stockist']::sales.tenant_role[]) and m.deleted_at is null)
);

-- recipes
drop policy if exists p_recipes_all on sales.recipes;
create policy p_recipes_all on sales.recipes
for all to authenticated
using (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid() and m.deleted_at is null)
)
with check (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid()
           and m.role = any (array['owner','manager','stockist']::sales.tenant_role[]) and m.deleted_at is null)
);

drop policy if exists p_recipe_comp_all on sales.recipe_components;
create policy p_recipe_comp_all on sales.recipe_components
for all to authenticated
using (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid() and m.deleted_at is null)
)
with check (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid()
           and m.role = any (array['owner','manager','stockist']::sales.tenant_role[]) and m.deleted_at is null)
);

-- orders / purchases
drop policy if exists p_sales_orders_select on sales.sales_orders;
create policy p_sales_orders_select on sales.sales_orders
for select to authenticated
using (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid() and m.deleted_at is null)
);

drop policy if exists p_sales_orders_insert on sales.sales_orders;
create policy p_sales_orders_insert on sales.sales_orders
for insert to authenticated
with check (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid()
           and m.role = any (array['owner','manager','cashier']::sales.tenant_role[]) and m.deleted_at is null)
);

drop policy if exists p_sales_orders_update on sales.sales_orders;
create policy p_sales_orders_update on sales.sales_orders
for update to authenticated
using (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid() and m.deleted_at is null)
)
with check (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid()
           and m.role = any (array['owner','manager','cashier']::sales.tenant_role[]) and m.deleted_at is null)
);

drop policy if exists p_sales_orders_del on sales.sales_orders;
create policy p_sales_orders_del on sales.sales_orders
for delete to authenticated
using (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid()
           and m.role = any (array['owner','manager']::sales.tenant_role[]) and m.deleted_at is null)
);

drop policy if exists p_sales_orders_service on sales.sales_orders;
create policy p_sales_orders_service on sales.sales_orders
for all to service_role
using (true) with check (true);

drop policy if exists p_sales_items_all on sales.sales_order_items;
create policy p_sales_items_all on sales.sales_order_items
for all to authenticated
using (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid() and m.deleted_at is null)
)
with check (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid()
           and m.role = any (array['owner','manager','cashier']::sales.tenant_role[]) and m.deleted_at is null)
);

drop policy if exists p_sales_items_service on sales.sales_order_items;
create policy p_sales_items_service on sales.sales_order_items
for all to service_role
using (true) with check (true);

drop policy if exists p_purchase_orders_select on sales.purchase_orders;
create policy p_purchase_orders_select on sales.purchase_orders
for select to authenticated
using (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid() and m.deleted_at is null)
);

drop policy if exists p_purchase_orders_insert on sales.purchase_orders;
create policy p_purchase_orders_insert on sales.purchase_orders
for insert to authenticated
with check (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid()
           and m.role = any (array['owner','manager','stockist']::sales.tenant_role[]) and m.deleted_at is null)
);

drop policy if exists p_purchase_orders_update on sales.purchase_orders;
create policy p_purchase_orders_update on sales.purchase_orders
for update to authenticated
using (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid() and m.deleted_at is null)
)
with check (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid()
           and m.role = any (array['owner','manager','stockist']::sales.tenant_role[]) and m.deleted_at is null)
);

drop policy if exists p_purchase_orders_del on sales.purchase_orders;
create policy p_purchase_orders_del on sales.purchase_orders
for delete to authenticated
using (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid()
           and m.role = any (array['owner','manager']::sales.tenant_role[]) and m.deleted_at is null)
);

drop policy if exists p_po_service on sales.purchase_orders;
create policy p_po_service on sales.purchase_orders
for all to service_role
using (true) with check (true);

drop policy if exists p_purchase_items_all on sales.purchase_order_items;
create policy p_purchase_items_all on sales.purchase_order_items
for all to authenticated
using (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid() and m.deleted_at is null)
)
with check (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid()
           and m.role = any (array['owner','manager','stockist']::sales.tenant_role[]) and m.deleted_at is null)
);

drop policy if exists p_poi_service on sales.purchase_order_items;
create policy p_poi_service on sales.purchase_order_items
for all to service_role
using (true) with check (true);

-- reviews & authenticity
drop policy if exists p_reviews_select on sales.product_reviews;
create policy p_reviews_select on sales.product_reviews
for select to authenticated
using (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid() and m.deleted_at is null)
);

drop policy if exists p_reviews_insert on sales.product_reviews;
create policy p_reviews_insert on sales.product_reviews
for insert to authenticated
with check (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid() and m.deleted_at is null)
);

drop policy if exists p_reviews_update on sales.product_reviews;
create policy p_reviews_update on sales.product_reviews
for update to authenticated
using (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid()
           and (m.role = any (array['owner','manager']::sales.tenant_role[]) or true) and m.deleted_at is null)
  and (created_by = auth.uid() or exists (
        select 1 from sales.tenant_memberships m2
        where m2.tenant_id = tenant_id and m2.user_id = auth.uid()
          and m2.role = any (array['owner','manager']::sales.tenant_role[]) and m2.deleted_at is null))
)
with check (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid()
           and (m.role = any (array['owner','manager']::sales.tenant_role[]) or true) and m.deleted_at is null)
  and (created_by = auth.uid() or exists (
        select 1 from sales.tenant_memberships m2
        where m2.tenant_id = tenant_id and m2.user_id = auth.uid()
          and m2.role = any (array['owner','manager']::sales.tenant_role[]) and m2.deleted_at is null))
);

drop policy if exists p_reviews_delete on sales.product_reviews;
create policy p_reviews_delete on sales.product_reviews
for delete to authenticated
using (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid()
           and (m.role = any (array['owner','manager']::sales.tenant_role[]) or true) and m.deleted_at is null)
  and (created_by = auth.uid() or exists (
        select 1 from sales.tenant_memberships m2
        where m2.tenant_id = tenant_id and m2.user_id = auth.uid()
          and m2.role = any (array['owner','manager']::sales.tenant_role[]) and m2.deleted_at is null))
);

drop policy if exists p_auth_reports_select on sales.authenticity_reports;
create policy p_auth_reports_select on sales.authenticity_reports
for select to authenticated
using (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid() and m.deleted_at is null)
);

drop policy if exists p_auth_reports_insert on sales.authenticity_reports;
create policy p_auth_reports_insert on sales.authenticity_reports
for insert to authenticated
with check (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid()
           and m.role = any (array['owner','manager','stockist']::sales.tenant_role[]) and m.deleted_at is null)
);

drop policy if exists p_auth_reports_update on sales.authenticity_reports;
create policy p_auth_reports_update on sales.authenticity_reports
for update to authenticated
using (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid()
           and m.role = any (array['owner','manager']::sales.tenant_role[]) and m.deleted_at is null)
)
with check (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid()
           and m.role = any (array['owner','manager']::sales.tenant_role[]) and m.deleted_at is null)
);

drop policy if exists p_auth_reports_service on sales.authenticity_reports;
create policy p_auth_reports_service on sales.authenticity_reports
for all to service_role
using (true) with check (true);

-- tax & summary
drop policy if exists p_tax_ledger_select on sales.tax_ledger;
create policy p_tax_ledger_select on sales.tax_ledger
for select to authenticated
using (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid() and m.deleted_at is null)
);

drop policy if exists p_tax_ledger_service on sales.tax_ledger;
create policy p_tax_ledger_service on sales.tax_ledger
for all to service_role
using (true) with check (true);

drop policy if exists p_daily_summary_select on sales.daily_sales_summary;
create policy p_daily_summary_select on sales.daily_sales_summary
for select to authenticated
using (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid() and m.deleted_at is null)
);

-- expenses
drop policy if exists p_expenses_all on sales.expenses;
create policy p_expenses_all on sales.expenses
for all to authenticated
using (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid() and m.deleted_at is null)
)
with check (
  exists (select 1 from sales.tenant_memberships m where m.tenant_id = tenant_id and m.user_id = auth.uid()
           and m.role = any (array['owner','manager']::sales.tenant_role[]) and m.deleted_at is null)
);

drop policy if exists p_expenses_service on sales.expenses;
create policy p_expenses_service on sales.expenses
for all to service_role
using (true) with check (true);


-- =====================================================================
-- 10) GRANTS
-- =====================================================================
revoke all on schema sales from anon;
grant usage on schema sales to authenticated, service_role;

grant select on all tables in schema public to authenticated;
grant select on all tables in schema sales to authenticated;

grant all on all tables in schema public to service_role;
grant all on all tables in schema sales to service_role;

-- ##############################################################
-- ##############################################################
