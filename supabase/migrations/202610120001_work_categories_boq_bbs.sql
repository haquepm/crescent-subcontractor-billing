-- Crescent Contractors: work categories, shared BOQ, subcontractor rates and BBS import
-- Additive migration. Existing rate_items and all operational records remain intact.

create table if not exists public.work_categories (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null unique,
  measurement_method text not null check (measurement_method in ('bbs','dimensions','surface_area','volume','linear','count','manual')),
  default_unit text not null,
  is_active boolean not null default true,
  display_order integer not null default 100,
  created_at timestamptz not null default now()
);

insert into public.work_categories(code,name,measurement_method,default_unit,display_order)
values
 ('STEEL','Steel Work','bbs','kg',10),
 ('SHUTTERING','Shuttering','surface_area','m2',20),
 ('BLOCK','Block Work','surface_area','m2',30),
 ('WATERPROOFING','Waterproofing','surface_area','m2',40),
 ('ANTI_TERMITE','Anti-Termite Treatment','surface_area','m2',50),
 ('PLASTERING','Plastering','surface_area','m2',60)
on conflict (code) do update set
 name=excluded.name,
 measurement_method=excluded.measurement_method,
 default_unit=excluded.default_unit,
 display_order=excluded.display_order;

-- Shared work-item catalogue, independent of any one subcontractor.
create table if not exists public.boq_items (
 id uuid primary key default gen_random_uuid(),
 work_category_id uuid not null references public.work_categories(id) on delete restrict,
 item_code text,
 work_item text not null,
 unit text not null,
 measurement_method text not null check (measurement_method in ('bbs','dimensions','surface_area','volume','linear','count','manual')),
 formula_key text not null default 'manual',
 is_active boolean not null default true,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create unique index if not exists boq_items_category_code_uq
 on public.boq_items(work_category_id,item_code) where item_code is not null;
create index if not exists boq_items_category_active_idx
 on public.boq_items(work_category_id,is_active);

-- One subcontractor may perform several categories.
create table if not exists public.subcontractor_work_categories (
 subcontractor_id uuid not null references public.subcontractors(id) on delete cascade,
 work_category_id uuid not null references public.work_categories(id) on delete restrict,
 created_at timestamptz not null default now(),
 primary key(subcontractor_id,work_category_id)
);

-- A BOQ item has a separate effective-dated negotiated rate per subcontractor.
create table if not exists public.subcontractor_rates (
 id uuid primary key default gen_random_uuid(),
 subcontractor_id uuid not null references public.subcontractors(id) on delete restrict,
 boq_item_id uuid not null references public.boq_items(id) on delete restrict,
 rate numeric(18,4) not null check(rate >= 0),
 effective_date date not null default current_date,
 end_date date,
 is_active boolean not null default true,
 notes text,
 created_at timestamptz not null default now(),
 check(end_date is null or end_date >= effective_date),
 unique(subcontractor_id,boq_item_id,effective_date)
);
create index if not exists subcontractor_rates_lookup_idx
 on public.subcontractor_rates(subcontractor_id,boq_item_id,effective_date desc);

-- BBS source workbook and one independently reviewable measurement per detected sheet.
create table if not exists public.measurement_bbs_uploads (
 id uuid primary key default gen_random_uuid(),
 project_id uuid not null references public.projects(id) on delete restrict,
 subcontractor_id uuid not null references public.subcontractors(id) on delete restrict,
 uploaded_by uuid not null references auth.users(id) on delete restrict,
 original_filename text not null,
 file_sha256 text not null,
 storage_path text,
 parser_version text,
 status text not null default 'uploaded'
   check(status in ('uploaded','parsed','needs_review','confirmed','submitted','failed')),
 parse_summary jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now(),
 unique(project_id,subcontractor_id,file_sha256)
);
create table if not exists public.measurement_bbs_sheets (
 id uuid primary key default gen_random_uuid(),
 upload_id uuid not null references public.measurement_bbs_uploads(id) on delete cascade,
 sheet_name text not null,
 structural_reference text,
 detected_total_weight_kg numeric(18,4),
 previous_released_kg numeric(18,4),
 held_quantity_kg numeric(18,4),
 proposed_current_release_kg numeric(18,4),
 confirmed_current_release_kg numeric(18,4),
 parser_status text not null default 'needs_review'
   check(parser_status in ('parsed','needs_review','formula_error','confirmed','rejected')),
 parser_warnings jsonb not null default '[]'::jsonb,
 measurement_id uuid references public.measurements(id) on delete set null,
 created_at timestamptz not null default now(),
 unique(upload_id,sheet_name)
);
create table if not exists public.measurement_bbs_items (
 id uuid primary key default gen_random_uuid(),
 bbs_sheet_id uuid not null references public.measurement_bbs_sheets(id) on delete cascade,
 bar_mark text,
 bar_diameter_mm numeric(8,2),
 bar_shape text,
 number_of_bars numeric(18,4),
 cutting_length_m numeric(18,5),
 total_length_m numeric(18,5),
 unit_weight_kg_m numeric(18,6),
 total_weight_kg numeric(18,4),
 source_row integer,
 source_data jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now()
);
create index if not exists measurement_bbs_items_sheet_idx on public.measurement_bbs_items(bbs_sheet_id);

-- Keep a durable calculation-method snapshot with existing measurements.
alter table public.measurements
 add column if not exists measurement_method text,
 add column if not exists work_category_id uuid references public.work_categories(id) on delete restrict,
 add column if not exists source_type text not null default 'manual'
   check(source_type in ('manual','bbs_excel')),
 add column if not exists source_reference text;

-- RLS: use the portal's existing authenticated-team access convention.
alter table public.work_categories enable row level security;
alter table public.boq_items enable row level security;
alter table public.subcontractor_work_categories enable row level security;
alter table public.subcontractor_rates enable row level security;
alter table public.measurement_bbs_uploads enable row level security;
alter table public.measurement_bbs_sheets enable row level security;
alter table public.measurement_bbs_items enable row level security;

do $$
declare t text;
begin
 foreach t in array array[
  'work_categories','boq_items','subcontractor_work_categories',
  'subcontractor_rates','measurement_bbs_uploads','measurement_bbs_sheets',
  'measurement_bbs_items'
 ] loop
  if not exists (
   select 1 from pg_policies
   where schemaname='public' and tablename=t and policyname='Authenticated team access'
  ) then
   execute format('create policy "Authenticated team access" on public.%I for all to authenticated using (true) with check (true)',t);
  end if;
 end loop;
end $$;

comment on table public.boq_items is 'Shared BOQ catalogue; contract prices are stored per subcontractor in subcontractor_rates.';
comment on table public.measurement_bbs_sheets is 'Each detected BBS worksheet is a separate measurement candidate and requires QS confirmation.';
comment on column public.measurements.source_type is 'Identifies manually entered measurements or BBS Excel-derived measurements.';
