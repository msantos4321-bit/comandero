-- Comandero 05: clientes con varios locales, aparatos conectados y comparativo de sucursales.
-- Se aplica UNA vez, después de 01–04.
--   · cm_restaurants.grupo: los locales de un mismo cliente (dueño) comparten grupo.
--   · cm_devices: cada aparato avisa que está conectado (solo para saber cuántos usa cada local; no hay límite).
--   · cm_grupo: el gerente (con su PIN) ve las ventas de todos los locales de su cliente.

alter table cm_restaurants add column if not exists grupo text;
create index if not exists cm_restaurants_grupo on cm_restaurants (grupo);

create table if not exists cm_devices (
  rest_id text not null references cm_restaurants(id) on delete cascade,
  dev text not null,
  info jsonb not null default '{}',
  primero timestamptz not null default now(),
  ultimo timestamptz not null default now(),
  primary key (rest_id, dev)
);
alter table cm_devices enable row level security;
revoke all on cm_devices from anon, authenticated;

-- El aparato avisa que está conectado (al abrir y cada pocos minutos)
create or replace function cm_ping(p_r text, p_k text, p_dev text, p_info jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare v cm_restaurants; i jsonb := coalesce(p_info, '{}'::jsonb);
begin
  v := cm_check(p_r, p_k);
  if coalesce(p_dev,'') !~ '^[A-Za-z0-9_-]{6,40}$' then raise exception 'Aparato no válido'; end if;
  if octet_length(i::text) > 400 then i := '{}'::jsonb; end if;
  insert into cm_devices(rest_id, dev, info) values (v.id, p_dev, i)
  on conflict (rest_id, dev) do update set ultimo = now(), info = excluded.info;
  delete from cm_devices where rest_id = v.id and ultimo < now() - interval '90 days';
end $$;

-- Cuántos locales activos tiene el cliente de este restaurante (para mostrar «Mis sucursales»)
create or replace function cm_sucursales_n(p_id text) returns integer
language sql stable security definer set search_path = public as $$
  select greatest(1, (select count(*)::int from cm_restaurants b
                       join cm_restaurants a on a.grupo = b.grupo
                      where a.id = p_id and a.grupo is not null and b.estado = 'activo'))
$$;

-- cm_get: igual que en 02, más el número de sucursales del cliente
create or replace function cm_get(p_r text, p_k text, p_since bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v cm_restaurants;
begin
  v := cm_check(p_r, p_k);
  return jsonb_build_object(
    'nombre', v.nombre,
    'features', v.features,
    'sucursales', cm_sucursales_n(v.id),
    'rev', coalesce((select max(rev) from cm_kv where rest_id = v.id), 0),
    'items', coalesce((select jsonb_agg(jsonb_build_object('kind',kind,'key',key,'data',data,'deleted',deleted,'rev',rev) order by rev)
                         from cm_kv where rest_id = v.id and rev > coalesce(p_since,0)), '[]'::jsonb));
end $$;

-- Comparativo de sucursales. Pide el código del local y el PIN de un Gerente de ese local.
create or replace function cm_grupo(p_r text, p_k text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v cm_restaurants; emp jsonb; tz text := 'America/Tijuana';
  hoy0 timestamptz; sem0 timestamptz; mes0 timestamptz; ant0 timestamptz; antX timestamptz;
  h bigint; s bigint; m bigint; a bigint; ax bigint;
begin
  v := cm_check(p_r, p_k);
  select data into emp from cm_kv where rest_id = v.id and kind = 'doc' and key = 'empleados' and not deleted;
  if not exists (select 1 from jsonb_array_elements(case when jsonb_typeof(emp) = 'array' then emp else '[]'::jsonb end) e
                  where e->>'pin' = coalesce(p_pin,'') and e->>'puesto' = 'Gerente') then
    raise exception 'Solo el gerente puede ver las sucursales';
  end if;
  hoy0 := date_trunc('day', now() at time zone tz) at time zone tz;
  sem0 := hoy0 - interval '6 days';
  mes0 := date_trunc('month', now() at time zone tz) at time zone tz;
  ant0 := (date_trunc('month', now() at time zone tz) - interval '1 month') at time zone tz;
  antX := ant0 + (now() - mes0);              -- mismo avance del mes pasado, para comparar parejo
  h := (extract(epoch from hoy0) * 1000)::bigint; s := (extract(epoch from sem0) * 1000)::bigint;
  m := (extract(epoch from mes0) * 1000)::bigint; a := (extract(epoch from ant0) * 1000)::bigint;
  ax := (extract(epoch from least(antX, mes0)) * 1000)::bigint;

  return jsonb_build_object(
    'cliente', coalesce(nullif(v.plan->>'cliente',''), v.nombre),
    'locales', coalesce((
      with r as (
        select id, nombre from cm_restaurants
         where estado = 'activo' and (id = v.id or (v.grupo is not null and grupo = v.grupo))
      ), o as (
        select k.rest_id, k.data->>'estado' est, nullif(k.data->>'pagadaT','')::bigint t,
               coalesce((k.data->'pago'->>'total')::numeric, 0) tot, k.data
          from cm_kv k join r on r.id = k.rest_id
         where k.kind = 'orden' and not k.deleted and k.data is not null
      )
      select jsonb_agg(jsonb_build_object(
        'id', r.id, 'nombre', r.nombre, 'yo', r.id = v.id,
        'hoy',        (select coalesce(sum(tot),0) from o where o.rest_id = r.id and est = 'pagada' and t >= h),
        'cuentas_hoy',(select count(*)          from o where o.rest_id = r.id and est = 'pagada' and t >= h),
        'semana',     (select coalesce(sum(tot),0) from o where o.rest_id = r.id and est = 'pagada' and t >= s),
        'mes',        (select coalesce(sum(tot),0) from o where o.rest_id = r.id and est = 'pagada' and t >= m),
        'cuentas_mes',(select count(*)          from o where o.rest_id = r.id and est = 'pagada' and t >= m),
        'mes_ant',    (select coalesce(sum(tot),0) from o where o.rest_id = r.id and est = 'pagada' and t >= a and t < m),
        'mes_ant_igual', (select coalesce(sum(tot),0) from o where o.rest_id = r.id and est = 'pagada' and t >= a and t < ax),
        'abiertas',   (select count(*) from o where o.rest_id = r.id and est = 'abierta'),
        'top', (select coalesce(jsonb_agg(jsonb_build_object('n', n, 'q', q) order by q desc), '[]'::jsonb) from (
                  select it->>'nombre' n, sum(coalesce((it->>'qty')::numeric,1)) q
                    from o, jsonb_array_elements(coalesce(o.data->'items','[]'::jsonb)) it
                   where o.rest_id = r.id and est = 'pagada' and t >= m
                     and not coalesce((it->>'cancel')::boolean, false) and coalesce(it->>'cat','') <> 'Envío'
                   group by 1 order by 2 desc limit 3) x),
        'ultimo', (select max(updated_at) from cm_kv where rest_id = r.id),
        'aparatos_hoy', (select count(*) from cm_devices d where d.rest_id = r.id and d.ultimo > now() - interval '24 hours')
      ) order by r.id <> v.id, r.nombre) from r), '[]'::jsonb));
end $$;

-- Panel: lista con grupo y aparatos
create or replace function cm_admin_list(p_s text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare mes timestamptz := date_trunc('month', now() at time zone 'America/Tijuana') at time zone 'America/Tijuana';
begin
  perform cm_owner_check(p_s);
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', r.id, 'nombre', r.nombre, 'code', r.code, 'estado', r.estado, 'features', r.features, 'plan', r.plan, 'created_at', r.created_at,
      'grupo', r.grupo,
      'ultimo', (select max(k.updated_at) from cm_kv k where k.rest_id = r.id),
      'aparatos', (select count(*) from cm_devices d where d.rest_id = r.id and d.ultimo > now() - interval '30 days'),
      'aparatos_hoy', (select count(*) from cm_devices d where d.rest_id = r.id and d.ultimo > now() - interval '24 hours'),
      'cuentas_mes', (select count(*) from cm_kv k where k.rest_id = r.id and k.kind = 'orden' and not k.deleted
                        and k.data->>'estado' = 'pagada' and to_timestamp((k.data->>'pagadaT')::bigint / 1000.0) >= mes),
      'venta_mes', (select coalesce(sum((k.data->'pago'->>'total')::numeric), 0) from cm_kv k where k.rest_id = r.id and k.kind = 'orden' and not k.deleted
                        and k.data->>'estado' = 'pagada' and to_timestamp((k.data->>'pagadaT')::bigint / 1000.0) >= mes)
    ) order by r.created_at) from cm_restaurants r), '[]'::jsonb);
end $$;

-- Panel: poner un local en el grupo de un cliente (o quitarlo con null)
create or replace function cm_admin_set_grupo(p_s text, p_id text, p_grupo text) returns void
language plpgsql security definer set search_path = public as $$
declare g text := nullif(lower(trim(coalesce(p_grupo,''))), '');
begin
  perform cm_owner_check(p_s);
  if g is not null and g !~ '^[a-z0-9][a-z0-9-]{2,59}$' then raise exception 'Cliente no válido'; end if;
  update cm_restaurants set grupo = g where id = lower(p_id);
  if not found then raise exception 'No existe ese restaurante'; end if;
end $$;

revoke all on function cm_sucursales_n(text) from public, anon, authenticated;
grant execute on function cm_ping(text,text,text,jsonb), cm_grupo(text,text,text), cm_admin_set_grupo(text,text,text) to anon, authenticated;

-- Los restaurantes que ya existen quedan cada uno como su propio cliente
update cm_restaurants set grupo = 'c-' || id where grupo is null;
