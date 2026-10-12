-- Allow remaining worksheets in a multi-sheet workbook to be submitted after the first sheet.
create or replace function public.submit_bbs_measurement(
 p_upload_id uuid,p_sheet_id uuid,p_subcontractor_rate_id uuid,p_measurement_date date,
 p_confirmed_current_release_kg numeric,p_location text default null,p_description text default null
) returns uuid language plpgsql security definer set search_path=''
as $function$
declare
 v_actor uuid:=auth.uid(); v_project uuid; v_sub uuid; v_boq uuid; v_category uuid;
 v_rate_item uuid; v_rate numeric; v_item text; v_unit text; v_method text; v_formula text;
 v_status text; v_measurement uuid; v_total numeric; v_prev numeric; v_held numeric;
begin
 if v_actor is null then raise exception 'Authentication is required.'; end if;
 if public.is_system_admin() then raise exception 'System Admin cannot submit measurements.'; end if;
 if p_measurement_date is null or p_confirmed_current_release_kg is null or p_confirmed_current_release_kg<=0 then raise exception 'A measurement date and positive current release quantity are required.'; end if;
 select u.project_id,u.subcontractor_id,sh.parser_status,sh.detected_total_weight_kg,sh.previous_released_kg,sh.held_quantity_kg
 into v_project,v_sub,v_status,v_total,v_prev,v_held
 from public.measurement_bbs_uploads u join public.measurement_bbs_sheets sh on sh.upload_id=u.id
 where u.id=p_upload_id and sh.id=p_sheet_id and u.status in ('parsed','needs_review','confirmed','submitted');
 if not found then raise exception 'BBS upload or worksheet was not found or is not ready.'; end if;
 if not public.current_user_has_project_role(v_project,'quantity_surveyor') then raise exception 'Only an assigned Quantity Surveyor can submit BBS measurements.'; end if;
 if v_status not in ('parsed','confirmed') then raise exception 'This worksheet has unresolved parsing errors or was already submitted.'; end if;
 if p_confirmed_current_release_kg>coalesce(v_total,0)-coalesce(v_prev,0)-coalesce(v_held,0)+0.001 then raise exception 'Current release exceeds total quantity less previous releases and held quantity.'; end if;
 select b.id,b.work_category_id,b.work_item,b.unit,b.measurement_method,b.formula_key,sr.rate
 into v_boq,v_category,v_item,v_unit,v_method,v_formula,v_rate
 from public.subcontractor_rates sr join public.boq_items b on b.id=sr.boq_item_id and b.is_active
 join public.subcontractors s on s.id=sr.subcontractor_id and s.active and s.project_id=v_project
 join public.subcontractor_work_categories swc on swc.subcontractor_id=s.id and swc.work_category_id=b.work_category_id
 join public.work_categories wc on wc.id=b.work_category_id
 where sr.id=p_subcontractor_rate_id and sr.subcontractor_id=v_sub and sr.is_active
 and sr.effective_date<=p_measurement_date and (sr.end_date is null or sr.end_date>=p_measurement_date)
 and b.measurement_method='bbs' and b.formula_key='bbs' and lower(wc.name) like '%steel%';
 if not found then raise exception 'Select an active BBS BOQ item and negotiated steel rate for this subcontractor.'; end if;
 select legacy_rate_item_id into v_rate_item from public.subcontractor_rates where id=p_subcontractor_rate_id for update;
 if v_rate_item is null then
  insert into public.rate_items(subcontractor_id,work_item,unit,rate,effective_date) values(v_sub,v_item,v_unit,v_rate,p_measurement_date) returning id into v_rate_item;
  update public.subcontractor_rates set legacy_rate_item_id=v_rate_item where id=p_subcontractor_rate_id;
 end if;
 insert into public.measurements(subcontractor_id,rate_item_id,measurement_date,quantity,location,description,measurement_method,work_category_id,source_type,source_reference,subcontractor_rate_id,boq_item_id)
 values(v_sub,v_rate_item,p_measurement_date,p_confirmed_current_release_kg,nullif(btrim(p_location),''),nullif(btrim(p_description),''),'bbs',v_category,'bbs_excel',
 (select original_filename||' / '||(select sheet_name from public.measurement_bbs_sheets where id=p_sheet_id) from public.measurement_bbs_uploads where id=p_upload_id),p_subcontractor_rate_id,v_boq)
 returning id into v_measurement;
 insert into public.measurement_workflows(measurement_id,submitted_by,status) values(v_measurement,v_actor,'pending_site_engineer');
 update public.measurement_bbs_sheets set confirmed_current_release_kg=p_confirmed_current_release_kg,measurement_id=v_measurement,parser_status='confirmed' where id=p_sheet_id;
 update public.measurement_bbs_uploads set status='submitted' where id=p_upload_id;
 return v_measurement;
end;$function$;
revoke all on function public.submit_bbs_measurement(uuid,uuid,uuid,date,numeric,text,text) from public,anon;
grant execute on function public.submit_bbs_measurement(uuid,uuid,uuid,date,numeric,text,text) to authenticated;