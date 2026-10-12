-- Additive bridge from shared BOQ rates to the existing RA-bill rate snapshot model.
-- No historical measurements, rates, or bills are rewritten.
alter table public.subcontractor_rates
  add column if not exists legacy_rate_item_id uuid references public.rate_items(id);
alter table public.measurements
  add column if not exists subcontractor_rate_id uuid references public.subcontractor_rates(id),
  add column if not exists boq_item_id uuid references public.boq_items(id);

create or replace function public.submit_categorized_measurement(
 p_subcontractor_id uuid,p_subcontractor_rate_id uuid,p_measurement_date date,
 p_component_rows jsonb default '[]'::jsonb,p_manual_quantity numeric default null,
 p_location text default null,p_description text default null
) returns uuid language plpgsql security definer set search_path=''
as $function$
declare
 v_actor uuid:=auth.uid(); v_project_id uuid; v_boq_id uuid; v_category_id uuid;
 v_work_item text; v_unit text; v_rate numeric; v_formula text; v_method text;
 v_rate_item_id uuid; v_measurement_id uuid; v_row jsonb; v_component text;
 v_no numeric; v_l numeric; v_b numeric; v_h numeric; v_qty numeric;
 v_total numeric:=0; v_i integer:=0;
begin
 if v_actor is null then raise exception 'Authentication is required.'; end if;
 if public.is_system_admin() then raise exception 'System Admin cannot submit measurements.'; end if;
 if p_measurement_date is null then raise exception 'Measurement date is required.'; end if;
 select s.project_id,b.id,b.work_category_id,b.work_item,b.unit,sr.rate,b.formula_key,b.measurement_method
 into v_project_id,v_boq_id,v_category_id,v_work_item,v_unit,v_rate,v_formula,v_method
 from public.subcontractor_rates sr
 join public.boq_items b on b.id=sr.boq_item_id and b.is_active
 join public.subcontractors s on s.id=sr.subcontractor_id and s.active
 join public.projects p on p.id=s.project_id and p.is_active
 join public.subcontractor_work_categories swc on swc.subcontractor_id=s.id and swc.work_category_id=b.work_category_id
 where sr.id=p_subcontractor_rate_id and sr.subcontractor_id=p_subcontractor_id
 and sr.is_active and sr.effective_date<=p_measurement_date
 and (sr.end_date is null or sr.end_date>=p_measurement_date);
 if not found then raise exception 'No active negotiated BOQ rate is assigned for this subcontractor and date.'; end if;
 if not public.current_user_has_project_role(v_project_id,'quantity_surveyor') then raise exception 'Only an assigned Quantity Surveyor can submit measurements.'; end if;
 if v_method='bbs' or v_formula='bbs' then raise exception 'Steel BBS items must use the BBS import workflow.'; end if;
 if v_formula='manual' then
  if p_manual_quantity is null or p_manual_quantity<=0 then raise exception 'Enter a positive manual quantity.'; end if;
  if coalesce(jsonb_array_length(p_component_rows),0)>0 then raise exception 'Manual quantity items cannot contain dimensional rows.'; end if;
  v_total:=p_manual_quantity;
 else
  if p_component_rows is null or jsonb_typeof(p_component_rows)<>'array' or jsonb_array_length(p_component_rows)=0 or jsonb_array_length(p_component_rows)>500 then raise exception 'Enter between 1 and 500 component rows.'; end if;
  for v_row in select value from jsonb_array_elements(p_component_rows) loop
   v_i:=v_i+1;
   if jsonb_typeof(v_row)<>'object' then raise exception 'Invalid component row %.',v_i; end if;
   v_component:=nullif(btrim(v_row->>'component_name'),'');
   if v_component is null then raise exception 'Component name is required in row %.',v_i; end if;
   v_no:=coalesce(nullif(btrim(v_row->>'no_value'),'')::numeric,1);
   v_l:=nullif(btrim(v_row->>'length'),'')::numeric; v_b:=nullif(btrim(v_row->>'breadth'),'')::numeric; v_h:=nullif(btrim(v_row->>'height'),'')::numeric;
   if v_no=0 or (v_l is not null and v_l<=0) or (v_b is not null and v_b<=0) or (v_h is not null and v_h<=0) then raise exception 'Invalid quantity or dimension in row %.',v_i; end if;
   if v_formula='area_lh' then
    if v_l is null or v_h is null or v_b is not null then raise exception 'area_lh requires Length and Height only in row %.',v_i; end if; v_qty:=v_no*v_l*v_h;
   elsif v_formula='area_lb' then
    if v_l is null or v_b is null or v_h is not null then raise exception 'area_lb requires Length and Breadth only in row %.',v_i; end if; v_qty:=v_no*v_l*v_b;
   elsif v_formula='volume_lbh' then
    if v_l is null or v_b is null or v_h is null then raise exception 'volume_lbh requires Length, Breadth and Height in row %.',v_i; end if; v_qty:=v_no*v_l*v_b*v_h;
   elsif v_formula='length_l' then
    if v_l is null or v_b is not null or v_h is not null then raise exception 'length_l requires Length only in row %.',v_i; end if; v_qty:=v_no*v_l;
   elsif v_formula='count' then
    if v_l is not null or v_b is not null or v_h is not null then raise exception 'count accepts No. only in row %.',v_i; end if; v_qty:=v_no;
   else raise exception 'Unsupported BOQ formula key: %.',coalesce(v_formula,'(null)'); end if;
   v_total:=v_total+v_qty;
  end loop;
  if v_total<=0 then raise exception 'Calculated quantity must be positive after deductions.'; end if;
 end if;
 select legacy_rate_item_id into v_rate_item_id from public.subcontractor_rates where id=p_subcontractor_rate_id for update;
 if v_rate_item_id is null then
  insert into public.rate_items(subcontractor_id,work_item,unit,rate,effective_date)
  values(p_subcontractor_id,v_work_item,v_unit,v_rate,p_measurement_date) returning id into v_rate_item_id;
  update public.subcontractor_rates set legacy_rate_item_id=v_rate_item_id where id=p_subcontractor_rate_id;
 end if;
 insert into public.measurements(subcontractor_id,rate_item_id,measurement_date,quantity,location,description,measurement_method,work_category_id,source_type,subcontractor_rate_id,boq_item_id)
 values(p_subcontractor_id,v_rate_item_id,p_measurement_date,v_total,nullif(btrim(p_location),''),nullif(btrim(p_description),''),v_method,v_category_id,'manual',p_subcontractor_rate_id,v_boq_id)
 returning id into v_measurement_id;
 if v_formula<>'manual' then
  v_i:=0;
  for v_row in select value from jsonb_array_elements(p_component_rows) loop
   v_i:=v_i+1; v_component:=nullif(btrim(v_row->>'component_name'),'');
   v_no:=coalesce(nullif(btrim(v_row->>'no_value'),'')::numeric,1);
   v_l:=nullif(btrim(v_row->>'length'),'')::numeric; v_b:=nullif(btrim(v_row->>'breadth'),'')::numeric; v_h:=nullif(btrim(v_row->>'height'),'')::numeric;
   if v_formula='area_lh' then v_qty:=v_no*v_l*v_h;
   elsif v_formula='area_lb' then v_qty:=v_no*v_l*v_b;
   elsif v_formula='volume_lbh' then v_qty:=v_no*v_l*v_b*v_h;
   elsif v_formula='length_l' then v_qty:=v_no*v_l;
   else v_qty:=v_no; end if;
   insert into public.measurement_details(measurement_id,row_number,component_name,no_value,length,breadth,height,calculated_quantity)
   values(v_measurement_id,v_i,v_component,v_no,v_l,v_b,v_h,v_qty);
  end loop;
 end if;
 insert into public.measurement_workflows(measurement_id,submitted_by,status) values(v_measurement_id,v_actor,'pending_site_engineer');
 return v_measurement_id;
end;$function$;
revoke all on function public.submit_categorized_measurement(uuid,uuid,date,jsonb,numeric,text,text) from public,anon;
grant execute on function public.submit_categorized_measurement(uuid,uuid,date,jsonb,numeric,text,text) to authenticated;