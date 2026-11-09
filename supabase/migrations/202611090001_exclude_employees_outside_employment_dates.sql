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
 if not exists(
  select 1 from public.regular_employee_project_assignments a
  join public.regular_employees e on e.id=a.employee_id
  where a.project_id=p_project_id and a.is_active
   and e.muster_category=v_category
   and e.joining_date<=p_period_to
   and (e.leaving_date is null or e.leaving_date>=p_period_from)
   and a.effective_from<=p_period_to
   and (a.effective_to is null or a.effective_to>=p_period_from)
 ) then
  raise exception 'No active employees in the selected muster category are assigned to this project for the selected period';
 end if;
 if exists(
  select 1
  from public.regular_employee_project_assignments a
  join public.regular_employees e on e.id=a.employee_id
  cross join lateral generate_series(
   greatest(p_period_from,coalesce(e.joining_date,p_period_from)),
   least(p_period_to,coalesce(e.leaving_date,p_period_to)),
   interval '1 day'
  ) g(day)
  left join public.regular_employee_attendance x
   on x.employee_id=e.id and x.project_id=p_project_id and x.attendance_date=g.day::date
  where a.project_id=p_project_id and a.is_active
   and e.muster_category=v_category
   and e.joining_date<=g.day::date
   and (e.leaving_date is null or e.leaving_date>=g.day::date)
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
    and a.attendance_date>=coalesce(e.joining_date,a.attendance_date)
    and (e.leaving_date is null or a.attendance_date<=e.leaving_date)
    and exists(
     select 1 from public.regular_employee_project_assignments pa
     where pa.employee_id=e.id and pa.project_id=p_project_id and pa.is_active
      and pa.effective_from<=a.attendance_date
      and (pa.effective_to is null or pa.effective_to>=a.attendance_date)
    )
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
revoke all on function public.generate_regular_employee_muster(uuid,date,date,text) from public,anon;
grant execute on function public.generate_regular_employee_muster(uuid,date,date,text) to authenticated,service_role;
