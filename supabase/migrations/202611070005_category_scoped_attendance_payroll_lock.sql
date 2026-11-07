-- Lock attendance only when the same employee muster category has a submitted/approved payroll.
create or replace function public.save_regular_employee_attendance(
 p_employee_id uuid,p_project_id uuid,p_attendance_date date,p_attendance_type text,
 p_overtime_hours numeric default 0,p_sunday_extra numeric default 0,p_remarks text default null,
 p_activity_code_id uuid default null,p_other_amount numeric default 0
) returns uuid language plpgsql security definer set search_path to 'public','auth'
as $function$
declare v_id uuid; v_employee_category text;
begin
 if auth.uid() is null or not public.regular_employee_can_manage_project(p_project_id) then raise exception 'Only an authorised Site Engineer or administrator can enter attendance'; end if;
 if p_attendance_date is null or p_attendance_type not in ('full_day','half_day','absent') then raise exception 'Valid attendance date and type are required'; end if;
 if coalesce(p_overtime_hours,0)<0 or coalesce(p_sunday_extra,0)<0 or coalesce(p_other_amount,0)<0 then raise exception 'Overtime, Sunday extra and Other amounts cannot be negative'; end if;
 if p_sunday_extra>0 and extract(isodow from p_attendance_date)<>7 then raise exception 'Sunday extra can only be entered for Sunday'; end if;
 if p_attendance_type in ('full_day','half_day') and p_activity_code_id is null then raise exception 'Select an activity code for every present employee'; end if;
 if p_activity_code_id is not null and not exists(select 1 from public.regular_activity_codes c where c.id=p_activity_code_id and c.project_id=p_project_id and c.is_active) then raise exception 'Select a valid activity code for this project'; end if;
 select e.muster_category into v_employee_category from public.regular_employees e join public.regular_employee_project_assignments a on a.employee_id=e.id where e.id=p_employee_id and e.is_active and a.project_id=p_project_id and a.is_active and a.effective_from<=p_attendance_date and (a.effective_to is null or a.effective_to>=p_attendance_date);
 if not found then raise exception 'Employee is not assigned to this project on the selected date'; end if;
 if exists(select 1 from public.regular_employee_musters m where m.project_id=p_project_id and m.muster_category=coalesce(v_employee_category,'labour') and p_attendance_date between m.period_from and m.period_to and m.status not in ('draft','rejected')) then raise exception 'Attendance belongs to a submitted or approved payroll for this employee category and cannot be changed'; end if;
 insert into public.regular_employee_attendance(employee_id,project_id,attendance_date,attendance_type,overtime_hours,sunday_extra,other_amount,remarks,created_by,activity_code_id)
 values(p_employee_id,p_project_id,p_attendance_date,p_attendance_type,coalesce(p_overtime_hours,0),coalesce(p_sunday_extra,0),coalesce(p_other_amount,0),nullif(btrim(p_remarks),''),auth.uid(),p_activity_code_id)
 on conflict(employee_id,attendance_date) do update set project_id=excluded.project_id,attendance_type=excluded.attendance_type,overtime_hours=excluded.overtime_hours,sunday_extra=excluded.sunday_extra,other_amount=excluded.other_amount,remarks=excluded.remarks,activity_code_id=excluded.activity_code_id,updated_at=now()
 returning id into v_id;
 return v_id;
end;
$function$;
revoke all on function public.save_regular_employee_attendance(uuid,uuid,date,text,numeric,numeric,text,uuid,numeric) from public,anon;
grant execute on function public.save_regular_employee_attendance(uuid,uuid,date,text,numeric,numeric,text,uuid,numeric) to authenticated,service_role;
notify pgrst,'reload schema';
