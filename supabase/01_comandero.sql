-- Comandero: datos de cada restaurante en la nube, sincronizados entre sus aparatos.
-- Cada restaurante tiene su propio espacio. Nadie lee ni escribe las tablas directo:
-- todo pasa por funciones cm_* que exigen el código del restaurante.

create extension if not exists pgcrypto;

create table if not exists cm_restaurants (
  id text primary key,                       -- ej. 'ribs28'
  nombre text not null,
  code_hash text not null,                   -- sha256 del código de acceso
  features jsonb not null default '{}',      -- interruptores por restaurante
  estado text not null default 'activo',     -- activo | pausado
  plan jsonb not null default '{}',          -- mensualidad, fecha de pago, notas
  created_at timestamptz not null default now()
);

create sequence if not exists cm_rev_seq;

-- kind 'doc' = config, menu, mesas…  kind 'orden' = una cuenta (key = id de la orden)
create table if not exists cm_kv (
  rest_id text not null references cm_restaurants(id) on delete cascade,
  kind text not null,
  key text not null,
  data jsonb,
  deleted boolean not null default false,
  rev bigint not null default nextval('cm_rev_seq'),
  updated_at timestamptz not null default clock_timestamp(),
  primary key (rest_id, kind, key)
);
create index if not exists cm_kv_rev on cm_kv (rest_id, rev);

create table if not exists cm_seq (
  rest_id text primary key references cm_restaurants(id) on delete cascade,
  n integer not null default 100
);

alter table cm_restaurants enable row level security;
alter table cm_kv enable row level security;
alter table cm_seq enable row level security;
revoke all on cm_restaurants, cm_kv, cm_seq from anon, authenticated;

create or replace function cm_check(p_r text, p_k text) returns cm_restaurants
language plpgsql security definer set search_path = public as $$
declare v cm_restaurants;
begin
  select * into v from cm_restaurants
   where id = lower(p_r) and code_hash = encode(extensions.digest(upper(trim(p_k)), 'sha256'), 'hex');
  if v.id is null then raise exception 'Código de restaurante incorrecto'; end if;
  if v.estado <> 'activo' then raise exception 'Este restaurante está pausado. Comunícate con tu proveedor.'; end if;
  return v;
end $$;

-- Para la pantalla de conectar: valida y regresa nombre e interruptores
create or replace function cm_join(p_r text, p_k text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v cm_restaurants;
begin
  v := cm_check(p_r, p_k);
  return jsonb_build_object('id', v.id, 'nombre', v.nombre, 'features', v.features,
    'vacio', not exists (select 1 from cm_kv where rest_id = v.id));
end $$;

-- Une dos versiones de un platillo de la cuenta: lo que ya pasó (enviado, listo, servido, cancelado) no se deshace.
create or replace function cm_merge_item(a jsonb, b jsonb) returns jsonb
language sql immutable as $$
  select (case when coalesce((a->>'u')::bigint,0) > coalesce((b->>'u')::bigint,0) then a else b end)
    || jsonb_build_object(
      'enviado', coalesce((a->>'enviado')::boolean,false) or coalesce((b->>'enviado')::boolean,false),
      'servido', coalesce((a->>'servido')::boolean,false) or coalesce((b->>'servido')::boolean,false),
      'cancel',  coalesce((a->>'cancel')::boolean,false)  or coalesce((b->>'cancel')::boolean,false),
      'borrado', coalesce((a->>'borrado')::boolean,false) or coalesce((b->>'borrado')::boolean,false),
      'estado', case when a->>'estado' = 'listo' or b->>'estado' = 'listo' then 'listo' else coalesce(b->>'estado', a->>'estado') end,
      't', coalesce(b->'t', a->'t'),
      'listoT', coalesce(b->'listoT', a->'listoT'))
$$;

-- Une dos versiones de una cuenta para que dos aparatos no se pisen (mesero agrega mientras cocina marca listo)
create or replace function cm_merge_order(o jsonb, n jsonb) returns jsonb
language plpgsql immutable as $$
declare r jsonb := n; items jsonb := '[]'::jsonb; it jsonb; oi jsonb;
begin
  if o is null then return n; end if;
  if coalesce(o->>'estado','abierta') <> 'abierta' and coalesce(n->>'estado','abierta') = 'abierta' then
    r := r || jsonb_build_object('estado', o->'estado', 'pago', o->'pago', 'pagadaT', o->'pagadaT');
  end if;
  for it in select x from jsonb_array_elements(coalesce(n->'items','[]'::jsonb)) x loop
    select x into oi from jsonb_array_elements(coalesce(o->'items','[]'::jsonb)) x where x->>'id' = it->>'id' limit 1;
    if oi is not null then it := cm_merge_item(oi, it); end if;
    items := items || jsonb_build_array(it);
    oi := null;
  end loop;
  for oi in select x from jsonb_array_elements(coalesce(o->'items','[]'::jsonb)) x loop
    if not exists (select 1 from jsonb_array_elements(coalesce(n->'items','[]'::jsonb)) y where y->>'id' = oi->>'id') then
      items := items || jsonb_build_array(oi);
    end if;
  end loop;
  return r || jsonb_build_object('items', items);
end $$;

-- Listas que solo crecen (movimientos, checadas, cortes): se juntan sin perder nada
create or replace function cm_union(a jsonb, b jsonb) returns jsonb
language sql immutable as $$
  select coalesce(jsonb_agg(x order by coalesce((x->>'t')::bigint,0)), '[]'::jsonb)
    from (select distinct x from (
      select jsonb_array_elements(coalesce(a,'[]'::jsonb)) x
      union all select jsonb_array_elements(coalesce(b,'[]'::jsonb))) u) d
$$;

-- items: [{kind, key, data, deleted}]  → regresa la revisión más nueva
create or replace function cm_put(p_r text, p_k text, p_items jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare v cm_restaurants; it jsonb; old jsonb; d jsonb; mx bigint := 0; nr bigint;
begin
  v := cm_check(p_r, p_k);
  if jsonb_array_length(coalesce(p_items,'[]'::jsonb)) > 500 then raise exception 'Demasiados cambios a la vez'; end if;
  for it in select x from jsonb_array_elements(p_items) x loop
    d := it->'data';
    select data into old from cm_kv where rest_id = v.id and kind = it->>'kind' and key = it->>'key';
    if old is not null and not coalesce((it->>'deleted')::boolean,false) then
      if it->>'kind' = 'orden' then d := cm_merge_order(old, d);
      elsif it->>'kind' = 'doc' and it->>'key' in ('movs','asist','cortes') then d := cm_union(old, d);
      end if;
    end if;
    nr := nextval('cm_rev_seq');
    insert into cm_kv(rest_id, kind, key, data, deleted, rev, updated_at)
      values (v.id, it->>'kind', it->>'key', d, coalesce((it->>'deleted')::boolean,false), nr, clock_timestamp())
    on conflict (rest_id, kind, key) do update
      set data = excluded.data, deleted = excluded.deleted, rev = excluded.rev, updated_at = excluded.updated_at;
    mx := greatest(mx, nr);
  end loop;
  return mx;
end $$;

-- Cambios desde la revisión p_since (0 = todo)
create or replace function cm_get(p_r text, p_k text, p_since bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v cm_restaurants;
begin
  v := cm_check(p_r, p_k);
  return jsonb_build_object(
    'features', v.features,
    'rev', coalesce((select max(rev) from cm_kv where rest_id = v.id), 0),
    'items', coalesce((select jsonb_agg(jsonb_build_object('kind',kind,'key',key,'data',data,'deleted',deleted,'rev',rev) order by rev)
                         from cm_kv where rest_id = v.id and rev > coalesce(p_since,0)), '[]'::jsonb));
end $$;

-- Número de cuenta consecutivo compartido por todos los aparatos
create or replace function cm_next_num(p_r text, p_k text) returns integer
language plpgsql security definer set search_path = public as $$
declare v cm_restaurants; n integer;
begin
  v := cm_check(p_r, p_k);
  insert into cm_seq(rest_id, n) values (v.id, 101)
  on conflict (rest_id) do update set n = cm_seq.n + 1
  returning cm_seq.n into n;
  return n;
end $$;

revoke all on function cm_check(text,text) from public, anon, authenticated;
grant execute on function cm_join(text,text), cm_put(text,text,jsonb), cm_get(text,text,bigint), cm_next_num(text,text) to anon, authenticated;
