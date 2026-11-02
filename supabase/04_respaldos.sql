-- Comandero: respaldo semanal automático de cada restaurante (se guardan los últimos 8).
create table if not exists cm_backups (
  id bigserial primary key,
  rest_id text not null references cm_restaurants(id) on delete cascade,
  created_at timestamptz not null default now(),
  data jsonb not null
);
create index if not exists cm_backups_rest on cm_backups (rest_id, created_at desc);
alter table cm_backups enable row level security;
revoke all on cm_backups from anon, authenticated;

create or replace function cm_backup_run() returns integer
language plpgsql security definer set search_path = public as $$
declare r record; n integer := 0;
begin
  for r in select id, nombre from cm_restaurants where coalesce(features->>'demo','false') <> 'true' loop
    insert into cm_backups(rest_id, data)
    select r.id, jsonb_build_object('app','Comandero','restaurante',r.id,'nombre',r.nombre,'fecha',now(),
             'items', coalesce(jsonb_agg(jsonb_build_object('kind',kind,'key',key,'data',data)), '[]'::jsonb))
      from cm_kv where rest_id = r.id and not deleted;
    delete from cm_backups where rest_id = r.id
       and id not in (select id from cm_backups where rest_id = r.id order by created_at desc limit 8);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function cm_backup_run() from public, anon, authenticated;

create or replace function cm_admin_backups(p_s text, p_id text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform cm_owner_check(p_s);
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'fecha', created_at, 'kb', round(octet_length(data::text) / 1024.0)) order by created_at desc)
                     from cm_backups where rest_id = lower(p_id)), '[]'::jsonb);
end $$;

create or replace function cm_admin_backup_get(p_s text, p_backup bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform cm_owner_check(p_s);
  return (select data from cm_backups where id = p_backup);
end $$;
grant execute on function cm_admin_backups(text,text), cm_admin_backup_get(text,bigint) to anon, authenticated;

-- Cada domingo a las 3 am de Tijuana (10:00 UTC)
create extension if not exists pg_cron;
select cron.schedule('comandero-respaldo-semanal', '0 10 * * 0', 'select public.cm_backup_run()');

-- Primer respaldo ahora mismo
select public.cm_backup_run() as restaurantes_respaldados;
