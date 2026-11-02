-- Comandero: panel del dueño (Mauricio). Una sola llave de dueño, guardada como sha256.
-- La llave en sí NO va en este archivo: se da de alta aparte en el editor de Supabase.

create table if not exists cm_owner (
  id integer primary key default 1 check (id = 1),
  secret_hash text not null
);
alter table cm_owner enable row level security;
revoke all on cm_owner from anon, authenticated;

-- Código visible para el dueño (para reenviar la liga a un restaurante)
alter table cm_restaurants add column if not exists code text;

create or replace function cm_owner_check(p_s text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from cm_owner where secret_hash = encode(extensions.digest(trim(coalesce(p_s,'')), 'sha256'), 'hex')) then
    raise exception 'Llave de dueño incorrecta';
  end if;
end $$;

create or replace function cm_gen_code(p_pre text) returns text
language plpgsql volatile set search_path = public as $$
declare a text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; s text := ''; b bytea := extensions.gen_random_bytes(8); i int;
begin
  for i in 0..7 loop s := s || substr(a, (get_byte(b, i) % 32) + 1, 1); end loop;
  return upper(coalesce(nullif(p_pre,''),'CM')) || '-' || substr(s,1,4) || '-' || substr(s,5,4);
end $$;

create or replace function cm_admin_list(p_s text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare mes timestamptz := date_trunc('month', now() at time zone 'America/Tijuana') at time zone 'America/Tijuana';
begin
  perform cm_owner_check(p_s);
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', r.id, 'nombre', r.nombre, 'code', r.code, 'estado', r.estado, 'features', r.features, 'plan', r.plan, 'created_at', r.created_at,
      'ultimo', (select max(k.updated_at) from cm_kv k where k.rest_id = r.id),
      'cuentas_mes', (select count(*) from cm_kv k where k.rest_id = r.id and k.kind = 'orden' and not k.deleted
                        and k.data->>'estado' = 'pagada' and to_timestamp((k.data->>'pagadaT')::bigint / 1000.0) >= mes),
      'venta_mes', (select coalesce(sum((k.data->'pago'->>'total')::numeric), 0) from cm_kv k where k.rest_id = r.id and k.kind = 'orden' and not k.deleted
                        and k.data->>'estado' = 'pagada' and to_timestamp((k.data->>'pagadaT')::bigint / 1000.0) >= mes)
    ) order by r.created_at) from cm_restaurants r), '[]'::jsonb);
end $$;

-- Alta de restaurante: regresa el código de acceso
create or replace function cm_admin_create(p_s text, p_id text, p_nombre text, p_plantilla text, p_plan jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare v_id text := lower(trim(p_id)); v_code text; v_pre text;
begin
  perform cm_owner_check(p_s);
  if v_id !~ '^[a-z0-9][a-z0-9-]{2,29}$' then raise exception 'El identificador solo lleva letras minúsculas, números o guiones (3 a 30)'; end if;
  if exists (select 1 from cm_restaurants where id = v_id) then raise exception 'Ya existe un restaurante con ese identificador'; end if;
  if length(trim(coalesce(p_nombre,''))) < 2 then raise exception 'Falta el nombre del restaurante'; end if;
  v_pre := upper(left(regexp_replace(translate(p_nombre,'áéíóúÁÉÍÓÚñÑ','aeiouAEIOUnN'), '[^A-Za-z]', '', 'g'), 2));
  v_code := cm_gen_code(v_pre);
  insert into cm_restaurants(id, nombre, code_hash, code, features, plan)
  values (v_id, trim(p_nombre), encode(extensions.digest(v_code, 'sha256'), 'hex'), v_code,
          jsonb_build_object('plantilla', coalesce(nullif(p_plantilla,''), 'blanco')), coalesce(p_plan, '{}'::jsonb));
  return v_code;
end $$;

create or replace function cm_admin_save(p_s text, p_id text, p_nombre text, p_estado text, p_features jsonb, p_plan jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform cm_owner_check(p_s);
  if p_estado not in ('activo','pausado') then raise exception 'Estado no válido'; end if;
  update cm_restaurants set nombre = coalesce(nullif(trim(p_nombre),''), nombre), estado = p_estado,
         features = coalesce(p_features, features), plan = coalesce(p_plan, plan)
   where id = lower(p_id);
  if not found then raise exception 'No existe ese restaurante'; end if;
end $$;

-- Código nuevo: los aparatos conectados con el código viejo tendrán que conectarse otra vez
create or replace function cm_admin_new_code(p_s text, p_id text) returns text
language plpgsql security definer set search_path = public as $$
declare v_code text; v_n text;
begin
  perform cm_owner_check(p_s);
  select nombre into v_n from cm_restaurants where id = lower(p_id);
  if v_n is null then raise exception 'No existe ese restaurante'; end if;
  v_code := cm_gen_code(upper(left(regexp_replace(translate(v_n,'áéíóúÁÉÍÓÚñÑ','aeiouAEIOUnN'), '[^A-Za-z]', '', 'g'), 2)));
  update cm_restaurants set code = v_code, code_hash = encode(extensions.digest(v_code, 'sha256'), 'hex') where id = lower(p_id);
  return v_code;
end $$;

revoke all on function cm_owner_check(text), cm_gen_code(text) from public, anon, authenticated;
grant execute on function cm_admin_list(text), cm_admin_create(text,text,text,text,jsonb), cm_admin_save(text,text,text,text,jsonb,jsonb), cm_admin_new_code(text,text) to anon, authenticated;

-- cm_get ahora también regresa el nombre (para arrancar un restaurante nuevo con su nombre)
create or replace function cm_get(p_r text, p_k text, p_since bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v cm_restaurants;
begin
  v := cm_check(p_r, p_k);
  return jsonb_build_object(
    'nombre', v.nombre,
    'features', v.features,
    'rev', coalesce((select max(rev) from cm_kv where rest_id = v.id), 0),
    'items', coalesce((select jsonb_agg(jsonb_build_object('kind',kind,'key',key,'data',data,'deleted',deleted,'rev',rev) order by rev)
                         from cm_kv where rest_id = v.id and rev > coalesce(p_since,0)), '[]'::jsonb));
end $$;
