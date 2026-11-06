-- Comandero 06: conectar un aparato solo con el código (sin escribir el nombre del restaurante), como en CineCasa.
-- Se aplica UNA vez, después de 01–05.
create or replace function cm_join_code(p_k text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v cm_restaurants;
begin
  select * into v from cm_restaurants
   where code_hash = encode(extensions.digest(upper(trim(coalesce(p_k,''))), 'sha256'), 'hex');
  if v.id is null then raise exception 'Ese código no existe. Revísalo con tu proveedor.'; end if;
  if v.estado <> 'activo' then raise exception 'Este restaurante está pausado. Comunícate con tu proveedor.'; end if;
  return jsonb_build_object('id', v.id, 'nombre', v.nombre);
end $$;
grant execute on function cm_join_code(text) to anon, authenticated;
