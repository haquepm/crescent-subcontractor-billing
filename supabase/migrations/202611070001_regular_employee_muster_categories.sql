-- Regular employee muster categories.
-- Existing employees and existing muster registers remain Labour Muster.
alter table public.regular_employees
 add column if not exists muster_category text not null default 'labour'
 check (muster_category in ('labour','union','welder'));

update public.regular_employees set muster_category='labour'
where muster_category is null or btrim(muster_category)='';

alter table public.regular_employee_musters
 add column if not exists muster_category text not null default 'labour'
 check (muster_category in ('labour','union','welder'));

update public.regular_employee_musters set muster_category='labour'
where muster_category is null or btrim(muster_category)='';

alter table public.regular_employee_musters
 drop constraint if exists regular_employee_musters_project_id_period_from_period_to_key;
alter table public.regular_employee_musters
 add constraint regular_employee_musters_project_period_category_key
 unique (project_id,period_from,period_to,muster_category);

create index if not exists regular_employee_musters_project_period_category_idx
 on public.regular_employee_musters(project_id,period_from,muster_category);
