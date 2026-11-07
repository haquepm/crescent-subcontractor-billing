create or replace function public.update_regular_employee_muster_category(
 p_employee_id uuid,
 p_muster_category text
) returns void
language plpgsql
security definer
set search_path to 'public','auth'
as $function$
declare v_category text;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if not (public.is_system_admin() or public.is_regular_employee_hr()) then
  raise exception 'Only HR or a system administrator can change an employee muster category';
 end if;
 v_category:=coalesce(nullif(btrim(p_muster_category),''),'labour');
 if v_category not in ('labour','union','welder') then
  raise exception 'Muster category must be labour, union or welder';
 end if;
 update public.regular_employees
 set muster_category=v_category,updated_at=now()
 where id=p_employee_id;
 if not found then raise exception 'Employee was not found'; end if;
end
$function$;
revoke all on function public.update_regular_employee_muster_category(uuid,text) from public,anon;
grant execute on function public.update_regular_employee_muster_category(uuid,text) to authenticated,service_role;
