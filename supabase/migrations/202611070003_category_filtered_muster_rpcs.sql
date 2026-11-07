CREATE OR REPLACE FUNCTION public.admin_create_regular_employee_with_wage(p_employee_code text, p_employee_name text, p_nature_of_work text, p_joining_date date, p_project_id uuid, p_wage_per_day numeric, p_overtime_rate numeric, p_mobile_number text DEFAULT NULL::text, p_muster_category text DEFAULT 'labour'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare v_employee_id uuid; v_is_admin boolean; v_category text;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 v_is_admin:=public.is_system_admin();
 if not v_is_admin and not exists(
   select 1 from public.project_assignments pa
   where pa.user_id=auth.uid() and pa.project_id=p_project_id
     and pa.role='site_engineer' and pa.is_active=true
 ) then
   raise exception 'Only an assigned Site Engineer or system administrator can register employees for this project';
 end if;
 if nullif(btrim(p_employee_code),'') is null or nullif(btrim(p_employee_name),'') is null
  or nullif(btrim(p_nature_of_work),'') is null then
  raise exception 'Employee code, name and nature of work are required';
 end if;
 if p_joining_date is null or p_wage_per_day is null or p_overtime_rate is null
  or p_wage_per_day<0 or p_overtime_rate<0 then
  raise exception 'Joining date, daily wage and overtime rate are required and cannot be negative';
 end if;
 if not exists(select 1 from public.projects p where p.id=p_project_id and p.is_active) then
  raise exception 'Select an active project';
 end if;
 v_category:=coalesce(nullif(btrim(p_muster_category),''),'labour');
 if v_category not in ('labour','union','welder') then
  raise exception 'Muster category must be labour, union or welder';
 end if;
 insert into public.regular_employees(employee_code,employee_name,nature_of_work,mobile_number,joining_date,created_by,muster_category)
 values(btrim(p_employee_code),btrim(p_employee_name),btrim(p_nature_of_work),nullif(btrim(p_mobile_number),''),p_joining_date,auth.uid(),v_category)
 returning id into v_employee_id;
 insert into public.regular_employee_project_assignments(employee_id,project_id,effective_from,assigned_by)
 values(v_employee_id,p_project_id,p_joining_date,auth.uid());
 insert into public.regular_employee_wage_history(employee_id,wage_per_day,overtime_rate,effective_from,created_by,remarks)
 values(v_employee_id,p_wage_per_day,p_overtime_rate,p_joining_date,auth.uid(),'Initial wage rates at employee registration');
 return v_employee_id;
end
$function$
;
revoke all on function public.admin_create_regular_employee_with_wage(text,text,text,date,uuid,numeric,numeric,text,text) from public,anon;
grant execute on function public.admin_create_regular_employee_with_wage(text,text,text,date,uuid,numeric,numeric,text,text) to authenticated,service_role;

CREATE OR REPLACE FUNCTION public.generate_regular_employee_muster(p_project_id uuid, p_period_from date, p_period_to date, p_muster_category text DEFAULT 'labour'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
 v_muster uuid; v_emp record; v_advrow record; v_line uuid;
 v_gross numeric(14,2); v_adv numeric(14,2);
 v_category text;
begin
 if auth.uid() is null or not (public.is_system_admin() or public.is_regular_employee_hr()) then
  raise exception 'Only HR or an administrator can prepare payroll';
 end if;
 v_category:=coalesce(nullif(btrim(p_muster_category),''),'labour');
 if v_category not in ('labour','union','welder') then
  raise exception 'Muster category must be labour, union or welder';
 end if;
 if p_period_from is null or p_period_to is null or p_period_to<p_period_from then
  raise exception 'Select a valid payroll date range';
 end if;
 if p_period_to <> p_period_from + 6 then
  raise exception 'Payroll period must be exactly seven consecutive days';
 end if;
 if exists(
  select 1
  from public.regular_employee_project_assignments a
  join public.regular_employees e on e.id=a.employee_id
  cross join generate_series(p_period_from,p_period_to,interval '1 day') g(day)
  left join public.regular_employee_attendance x
   on x.employee_id=e.id and x.project_id=p_project_id and x.attendance_date=g.day::date
  where a.project_id=p_project_id and e.is_active and a.is_active
   and e.muster_category=v_category
   and a.effective_from<=g.day::date
   and (a.effective_to is null or a.effective_to>=g.day::date)
   and x.id is null
 ) then
  raise exception 'Daily attendance is incomplete. Record Full Day, Half Day or Absent for every assigned employee in this muster category for all seven days before preparing payroll.';
 end if;
 if exists(
  select 1 from public.regular_employee_musters m
  where m.project_id=p_project_id
   and m.muster_category=v_category
   and daterange(m.period_from,m.period_to,'[]') && daterange(p_period_from,p_period_to,'[]')
   and m.status not in ('draft','rejected')
   and not (m.period_from=p_period_from and m.period_to=p_period_to)
 ) then
  raise exception 'This date range overlaps an existing submitted muster for the selected category';
 end if;
 insert into public.regular_employee_musters(project_id,period_from,period_to,created_by,status,muster_category)
 values(p_project_id,p_period_from,p_period_to,auth.uid(),'draft',v_category)
 on conflict(project_id,period_from,period_to,muster_category)
 do update set updated_at=now()
 returning id into v_muster;
 if exists(select 1 from public.regular_employee_musters where id=v_muster and status not in ('draft','rejected')) then
  raise exception 'This muster has already been submitted';
 end if;
 delete from public.regular_employee_muster_lines where muster_id=v_muster;
 delete from public.regular_employee_muster_advance_applications where muster_id=v_muster;
 for v_emp in
  with daily as (
   select e.id employee_id,e.employee_code,e.employee_name,
    count(*) filter(where a.attendance_type='full_day')::numeric full_days,
    count(*) filter(where a.attendance_type='half_day')::numeric half_days,
    coalesce(sum(a.overtime_hours),0) ot_hours,
    coalesce(sum(a.sunday_extra),0) sunday_extra,
    coalesce(sum(a.other_amount),0) other_amount,
    coalesce(sum(case when a.attendance_type='full_day' then w.wage_per_day when a.attendance_type='half_day' then w.wage_per_day/2 else 0 end),0) basic_amount,
    coalesce(sum(a.overtime_hours*w.overtime_rate),0) ot_amount,
    jsonb_agg(jsonb_build_object('date',a.attendance_date,'attendance',a.attendance_type,'wage_per_day',w.wage_per_day,'overtime_rate',w.overtime_rate,'overtime_hours',a.overtime_hours) order by a.attendance_date) wage_breakdown
   from public.regular_employee_attendance a
   join public.regular_employees e on e.id=a.employee_id
   left join lateral(
    select h.wage_per_day,h.overtime_rate
    from public.regular_employee_wage_history h
    where h.employee_id=e.id and h.effective_from<=a.attendance_date
     and (h.effective_to is null or h.effective_to>=a.attendance_date)
    order by h.effective_from desc limit 1
   ) w on true
   where a.project_id=p_project_id
    and a.attendance_date between p_period_from and p_period_to
    and e.muster_category=v_category
   group by e.id,e.employee_code,e.employee_name
  )
  select *,round(basic_amount,2) basic_amount_rounded,
   round(ot_amount,2) ot_amount_rounded,
   round((basic_amount+ot_amount+sunday_extra+other_amount),2) gross
  from daily
  where full_days+half_days+ot_hours>0 or sunday_extra>0 or other_amount>0
 loop
  if v_emp.wage_breakdown is null or jsonb_array_length(v_emp.wage_breakdown)=0
   or exists(select 1 from jsonb_array_elements(v_emp.wage_breakdown) x
    where x->>'wage_per_day' is null or x->>'overtime_rate' is null) then
   raise exception 'Missing effective wage or OT rate for employee % on one or more attendance dates',v_emp.employee_code;
  end if;
  v_gross:=round(v_emp.gross,2); v_adv:=0;
  for v_advrow in
   select id,amount-deducted_amount outstanding
   from public.regular_employee_advances
   where employee_id=v_emp.employee_id and project_id=p_project_id
    and status in ('approved','partly_deducted')
    and advance_date<=p_period_to and deducted_amount<amount
   order by advance_date,created_at for update
  loop
   exit when v_adv>=v_gross;
   v_adv:=v_adv+least(v_advrow.outstanding,v_gross-v_adv);
  end loop;
  insert into public.regular_employee_muster_lines(
   muster_id,employee_id,employee_code_snapshot,employee_name_snapshot,
   full_days,half_days,overtime_hours,basic_amount,overtime_amount,
   sunday_extra,other_amount,gross_amount,advance_deduction,net_amount,wage_breakdown
  )
  values(
   v_muster,v_emp.employee_id,v_emp.employee_code,v_emp.employee_name,
   v_emp.full_days,v_emp.half_days,v_emp.ot_hours,v_emp.basic_amount_rounded,
   v_emp.ot_amount_rounded,round(v_emp.sunday_extra,2),round(v_emp.other_amount,2),
   v_gross,round(v_adv,2),round(v_gross-v_adv,2),v_emp.wage_breakdown
  )
  returning id into v_line;
 end loop;
 update public.regular_employee_musters m
 set total_basic=coalesce((select sum(basic_amount) from public.regular_employee_muster_lines where muster_id=v_muster),0),
  total_overtime=coalesce((select sum(overtime_amount) from public.regular_employee_muster_lines where muster_id=v_muster),0),
  total_sunday_extra=coalesce((select sum(sunday_extra) from public.regular_employee_muster_lines where muster_id=v_muster),0),
  total_other=coalesce((select sum(other_amount) from public.regular_employee_muster_lines where muster_id=v_muster),0),
  total_gross=coalesce((select sum(gross_amount) from public.regular_employee_muster_lines where muster_id=v_muster),0),
  total_advance_deduction=coalesce((select sum(advance_deduction) from public.regular_employee_muster_lines where muster_id=v_muster),0),
  total_net=coalesce((select sum(net_amount) from public.regular_employee_muster_lines where muster_id=v_muster),0),
  updated_at=now()
 where id=v_muster;
 return v_muster;
end
$function$
;
revoke all on function public.generate_regular_employee_muster(uuid,date,date,text) from public,anon;
grant execute on function public.generate_regular_employee_muster(uuid,date,date,text) to authenticated,service_role;
