-- Comandero: demostración en la nube para enseñar a restaurantes en dos aparatos.
-- Solo un restaurante con features.demo = true se puede reiniciar desde la app.
create or replace function cm_demo_reset(p_r text, p_k text) returns void
language plpgsql security definer set search_path = public as $$
declare v cm_restaurants;
begin
  v := cm_check(p_r, p_k);
  if coalesce(v.features->>'demo','false') <> 'true' then raise exception 'Solo la demostración se puede reiniciar'; end if;
  update cm_kv set deleted = true, data = null, rev = nextval('cm_rev_seq'), updated_at = clock_timestamp() where rest_id = v.id and not deleted;
  update cm_seq set n = 100 where rest_id = v.id;
end $$;
grant execute on function cm_demo_reset(text,text) to anon, authenticated;
