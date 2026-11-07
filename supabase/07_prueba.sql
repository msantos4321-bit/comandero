-- Comandero 07: «Probar en 2 aparatos».
-- Desde cualquier demostración (general o preparada) se crea una prueba temporal en la nube,
-- para que el celular (mesero) y la tablet (cocina) vean lo mismo al instante.
-- Las pruebas duran 3 días y se borran solas. Máximo 40 nuevas por hora.

create or replace function cm_prueba_crear(p_p text, p_nombre text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_p text := lower(trim(coalesce(p_p,''))); v_n text := left(trim(coalesce(p_nombre,'')), 60);
        v_id text; v_code text;
begin
  if v_p <> '' and v_p !~ '^[a-z0-9-]{2,60}$' then raise exception 'Demostración no válida'; end if;
  if v_n = '' then v_n := 'Demostración'; end if;
  delete from cm_restaurants where features->>'prueba' = 'true' and created_at < now() - interval '3 days';
  if (select count(*) from cm_restaurants where features->>'prueba' = 'true' and created_at > now() - interval '1 hour') >= 40 then
    raise exception 'Hay muchas pruebas abiertas en este momento. Intenta en un rato.';
  end if;
  loop
    v_id := 'prueba-' || lower(replace(substr(cm_gen_code('X'), 3), '-', ''));
    exit when not exists (select 1 from cm_restaurants where id = v_id);
  end loop;
  v_code := cm_gen_code('PR');
  insert into cm_restaurants(id, nombre, code_hash, code, features, plan)
  values (v_id, 'Prueba en 2 aparatos · ' || v_n, encode(extensions.digest(v_code, 'sha256'), 'hex'), v_code,
          jsonb_build_object('plantilla', 'demo', 'demo', true, 'prueba', true, 'p', v_p), '{}'::jsonb);
  return jsonb_build_object('id', v_id, 'k', v_code);
end $$;
grant execute on function cm_prueba_crear(text, text) to anon, authenticated;
