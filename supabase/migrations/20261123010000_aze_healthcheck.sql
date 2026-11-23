begin;

create or replace function public.aze_healthcheck()
returns boolean
language sql stable
set search_path = ''
as $$
  select true
$$;

revoke all on function public.aze_healthcheck() from public, anon, authenticated;
grant execute on function public.aze_healthcheck() to anon, authenticated;

commit;
