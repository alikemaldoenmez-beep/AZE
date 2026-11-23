-- Erstinstallation für ein leeres Supabase-Projekt.

-- Aus den versionierten Migrationen in supabase/migrations erzeugt.

begin;

-- 20261120000000_initial_schema.sql
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
grant usage on schema private to authenticated;

create type public.app_role as enum ('admin', 'employee');
create type public.entry_status as enum ('open', 'recorded', 'submitted', 'approved', 'rejected');
create type public.absence_type as enum ('vacation', 'sick', 'comp_time', 'other');
create type public.absence_status as enum ('submitted', 'approved', 'rejected');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete restrict,
  full_name text not null check (btrim(full_name) <> ''),
  role public.app_role not null default 'employee',
  weekly_hours numeric(5,2) not null default 40 check (weekly_hours between 0 and 168),
  annual_leave_days numeric(5,2) not null default 30 check (annual_leave_days between 0 and 366),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.company_settings (
  id smallint primary key default 1 check (id = 1),
  auto_break_start time not null default '12:00' check (auto_break_start < time '24:00'),
  auto_break_minutes integer not null default 30 check (auto_break_minutes between 0 and 1440)
);
insert into public.company_settings default values;

create table public.time_entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id),
  started_at timestamptz not null check (isfinite(started_at)),
  ended_at timestamptz check (isfinite(ended_at)),
  break_minutes integer not null default 0 check (break_minutes >= 0),
  break_adjusted boolean not null default false,
  note text,
  status public.entry_status not null default 'open',
  correction_reason text,
  corrects_entry_id uuid references public.time_entries(id),
  approved_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  check (corrects_entry_id is null or (corrects_entry_id <> id and status in ('submitted', 'approved', 'rejected'))),
  check ((status = 'open') = (ended_at is null)),
  check (ended_at is null or (ended_at > started_at and
    break_minutes * interval '1 minute' <= ended_at - started_at)),
  check (status <> 'submitted' or nullif(btrim(correction_reason), '') is not null)
);
create unique index time_entries_one_open on public.time_entries (user_id) where status = 'open';
create unique index time_entries_one_pending_correction on public.time_entries (corrects_entry_id)
where status = 'submitted' and corrects_entry_id is not null;
create index time_entries_user_start on public.time_entries (user_id, started_at);

create table public.absences (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id),
  type public.absence_type not null,
  start_date date not null check (isfinite(start_date)),
  end_date date not null check (isfinite(end_date) and end_date >= start_date),
  status public.absence_status not null default 'submitted',
  note text,
  created_at timestamptz not null default now()
);
create index absences_user_start on public.absences (user_id, start_date);

create table public.monthly_summaries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id),
  year integer not null check (year between 1 and 9999),
  month integer not null check (month between 1 and 12),
  target_minutes integer not null default 0 check (target_minutes >= 0),
  worked_minutes integer not null default 0 check (worked_minutes >= 0),
  break_minutes integer not null default 0 check (break_minutes >= 0),
  balance_minutes integer not null default 0,
  carryover_minutes integer not null default 0,
  vacation_days integer not null default 0 check (vacation_days >= 0),
  sick_days integer not null default 0 check (sick_days >= 0),
  comp_time_days integer not null default 0 check (comp_time_days >= 0),
  is_locked boolean not null default false,
  closed_by uuid references public.profiles(id),
  closed_at timestamptz,
  unique (user_id, year, month),
  check (not is_locked or (closed_by is not null and closed_at is not null))
);

create function private.is_active_member() returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select from public.profiles where id = auth.uid() and is_active)
$$;

create function private.is_admin() returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select from public.profiles where id = auth.uid() and is_active and role = 'admin')
$$;

create function private.lock_user(owner_id uuid) returns void
language sql set search_path = ''
as $$
  select pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(owner_id::text, 0))
$$;

create function private.assert_unlocked(owner_id uuid, first_day date, last_day date) returns void
language plpgsql set search_path = ''
as $$
begin
  if exists (
    select from public.monthly_summaries s
    where s.user_id = owner_id and s.is_locked
      and (s.year * 12 + s.month) between
        (extract(year from first_day) * 12 + extract(month from first_day)) and
        (extract(year from last_day) * 12 + extract(month from last_day))
  ) then
    raise exception 'Der Monat ist bereits abgeschlossen.' using errcode = '42501';
  end if;
end
$$;

create function private.automatic_break(
  started timestamptz, ended timestamptz, pause_start time, pause_minutes integer
) returns integer language sql stable set search_path = ''
as $$
  select (count(*) * pause_minutes)::integer
  from pg_catalog.generate_series(
    0, (ended at time zone 'Europe/Berlin')::date - (started at time zone 'Europe/Berlin')::date
  ) as days(offset_days)
  cross join lateral (
    select (((started at time zone 'Europe/Berlin')::date + days.offset_days) + pause_start)
      at time zone 'Europe/Berlin' as begins
  ) as pause
  where started < pause.begins and ended > pause.begins + make_interval(mins => pause_minutes)
$$;

create function private.guard_time_entry() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  settings public.company_settings%rowtype;
  original public.time_entries%rowtype;
begin
  perform private.lock_user(case when tg_op = 'DELETE' then old.user_id else new.user_id end);
  if tg_op = 'DELETE' then return old; end if;
  if auth.uid() is null or private.is_admin() then
    if new.status = 'recorded' and not new.break_adjusted then
      select * into strict settings from public.company_settings where id = 1;
      new.break_minutes := private.automatic_break(
        new.started_at, new.ended_at, settings.auto_break_start, settings.auto_break_minutes);
    end if;
    return new;
  end if;

  if tg_op = 'UPDATE' then
    if new.id <> old.id or new.user_id <> old.user_id or new.created_at <> old.created_at
      or new.corrects_entry_id is distinct from old.corrects_entry_id then
      raise exception 'Geschützte Buchungsfelder.' using errcode = '42501';
    end if;
    perform private.assert_unlocked(old.user_id, (old.started_at at time zone 'Europe/Berlin')::date,
      (coalesce(old.ended_at, old.started_at) at time zone 'Europe/Berlin')::date);
  else
    new.created_at := statement_timestamp();
  end if;

  if new.approved_by is not null then
    raise exception 'Freigaben erfordern Adminrechte.' using errcode = '42501';
  end if;

  if tg_op = 'INSERT' and new.status = 'open' then
    new.started_at := clock_timestamp();
    new.ended_at := null;
    new.break_minutes := 0;
    new.break_adjusted := false;
  elsif tg_op = 'UPDATE' and old.status = 'open' and new.status = 'recorded' then
    new.started_at := old.started_at;
    new.ended_at := clock_timestamp();
  elsif new.status <> 'submitted' or (tg_op = 'UPDATE' and old.status <> 'submitted') then
    raise exception 'Historische Zeiten erfordern einen Korrekturantrag.' using errcode = '42501';
  end if;

  if new.corrects_entry_id is not null then
    select * into original from public.time_entries
    where id = new.corrects_entry_id and user_id = new.user_id
      and status in ('open', 'recorded', 'approved');
    if not found then
      raise exception 'Ungültiger Bezug für den Korrekturantrag.' using errcode = '42501';
    end if;
    perform private.assert_unlocked(original.user_id, (original.started_at at time zone 'Europe/Berlin')::date,
      (coalesce(original.ended_at, original.started_at) at time zone 'Europe/Berlin')::date);
  end if;

  if new.ended_at is not null and not new.break_adjusted then
    select * into strict settings from public.company_settings where id = 1;
    new.break_minutes := private.automatic_break(
      new.started_at, new.ended_at, settings.auto_break_start, settings.auto_break_minutes);
  end if;

  perform private.assert_unlocked(new.user_id, (new.started_at at time zone 'Europe/Berlin')::date,
    (coalesce(new.ended_at, new.started_at) at time zone 'Europe/Berlin')::date);
  return new;
end
$$;

create function private.guard_absence() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  perform private.lock_user(case when tg_op = 'DELETE' then old.user_id else new.user_id end);
  if tg_op <> 'DELETE' and new.status = 'approved' and exists (
    select from public.absences a
    where a.user_id = new.user_id and a.id <> new.id and a.status = 'approved'
      and a.start_date <= new.end_date and a.end_date >= new.start_date
  ) then
    raise exception 'Genehmigte Abwesenheiten überschneiden sich.' using errcode = '23P01';
  end if;

  if auth.uid() is null or private.is_admin() then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;

  if tg_op <> 'INSERT' then
    perform private.assert_unlocked(old.user_id, old.start_date, old.end_date);
  end if;
  if tg_op = 'DELETE' then return old; end if;
  if tg_op = 'UPDATE' and
    (new.id <> old.id or new.user_id <> old.user_id or new.created_at <> old.created_at) then
    raise exception 'Geschützte Abwesenheitsfelder.' using errcode = '42501';
  end if;
  if tg_op = 'INSERT' then new.created_at := statement_timestamp(); end if;
  perform private.assert_unlocked(new.user_id, new.start_date, new.end_date);
  return new;
end
$$;

create function private.guard_summary() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  perform private.lock_user(case when tg_op = 'DELETE' then old.user_id else new.user_id end);
  if tg_op = 'DELETE' then return old; end if;
  if tg_op = 'UPDATE' and (new.user_id, new.year, new.month) <> (old.user_id, old.year, old.month) then
    raise exception 'Der Schlüssel eines Monatsabschlusses ist fest.';
  end if;
  return new;
end
$$;

create trigger guard_time_entry before insert or update or delete on public.time_entries
for each row execute function private.guard_time_entry();
create trigger guard_absence before insert or update or delete on public.absences
for each row execute function private.guard_absence();
create trigger guard_summary before insert or update or delete on public.monthly_summaries
for each row execute function private.guard_summary();

alter table public.profiles enable row level security;
alter table public.company_settings enable row level security;
alter table public.time_entries enable row level security;
alter table public.absences enable row level security;
alter table public.monthly_summaries enable row level security;

create policy profiles_admin on public.profiles for all to authenticated
using (private.is_admin()) with check (private.is_admin());
create policy profiles_own on public.profiles for select to authenticated
using (id = auth.uid() and is_active);

create policy settings_admin on public.company_settings for update to authenticated
using (private.is_admin()) with check (private.is_admin());
create policy settings_read on public.company_settings for select to authenticated
using (private.is_active_member());

create policy entries_admin on public.time_entries for all to authenticated
using (private.is_admin()) with check (private.is_admin());
create policy entries_own on public.time_entries for select to authenticated
using (user_id = auth.uid() and private.is_active_member());
create policy entries_insert on public.time_entries for insert to authenticated
with check (user_id = auth.uid() and private.is_active_member() and status in ('open', 'submitted'));
create policy entries_update on public.time_entries for update to authenticated
using (user_id = auth.uid() and private.is_active_member() and status in ('open', 'submitted'))
with check (user_id = auth.uid() and private.is_active_member() and status in ('recorded', 'submitted'));

create policy absences_admin on public.absences for all to authenticated
using (private.is_admin()) with check (private.is_admin());
create policy absences_own on public.absences for select to authenticated
using (user_id = auth.uid() and private.is_active_member());
create policy absences_insert on public.absences for insert to authenticated
with check (user_id = auth.uid() and private.is_active_member() and status = 'submitted');
create policy absences_update on public.absences for update to authenticated
using (user_id = auth.uid() and private.is_active_member() and status = 'submitted')
with check (user_id = auth.uid() and private.is_active_member() and status = 'submitted');
create policy absences_delete on public.absences for delete to authenticated
using (user_id = auth.uid() and private.is_active_member() and status = 'submitted');

create policy summaries_admin on public.monthly_summaries for all to authenticated
using (private.is_admin()) with check (private.is_admin());
create policy summaries_own on public.monthly_summaries for select to authenticated
using (user_id = auth.uid() and private.is_active_member());

-- Kalenderdaten enthalten bewusst keine internen Notizen.
create function public.team_calendar(first_day date, last_day date)
returns table (
  id uuid, user_id uuid, full_name text, type public.absence_type,
  start_date date, end_date date, status public.absence_status
)
language sql stable security definer set search_path = ''
as $$
  select a.id, a.user_id, p.full_name, a.type, a.start_date, a.end_date, a.status
  from public.absences a join public.profiles p on p.id = a.user_id
  where first_day <= last_day and a.start_date <= last_day and a.end_date >= first_day
    and private.is_active_member()
    and (private.is_admin() or a.user_id = auth.uid() or
      (a.status = 'approved' and a.type <> 'sick'))
$$;

revoke all on all functions in schema private from public, anon, authenticated;
grant execute on function private.is_active_member(), private.is_admin() to authenticated;
revoke all on function public.team_calendar(date, date) from public, anon, authenticated;
grant execute on function public.team_calendar(date, date) to authenticated;

revoke all on public.profiles, public.company_settings, public.time_entries, public.absences,
  public.monthly_summaries from public, anon, authenticated;
grant select, insert, update, delete on public.profiles, public.time_entries, public.absences,
  public.monthly_summaries to authenticated;
grant select, update on public.company_settings to authenticated;

-- 20261120010000_desktop_clock.sql
create function public.clock_in() returns uuid
language plpgsql set search_path = ''
as $$
declare
  member_id uuid := auth.uid();
  entry_id uuid;
begin
  if not private.is_active_member() then
    raise exception 'Ein aktives Profil ist erforderlich.' using errcode = '42501';
  end if;

  insert into public.time_entries (user_id, started_at, status)
  values (member_id, clock_timestamp(), 'open')
  returning id into entry_id;

  return entry_id;
end
$$;

create function public.clock_out(entry_id uuid, adjusted_break integer default null, entry_note text default null)
returns uuid
language plpgsql set search_path = ''
as $$
declare
  updated_id uuid;
begin
  if not private.is_active_member() then
    raise exception 'Ein aktives Profil ist erforderlich.' using errcode = '42501';
  end if;

  update public.time_entries
  set ended_at = clock_timestamp(),
      status = 'recorded',
      break_adjusted = adjusted_break is not null,
      break_minutes = coalesce(adjusted_break, 0),
      note = coalesce(nullif(btrim(entry_note), ''), note)
  where id = entry_id and user_id = auth.uid() and status = 'open'
  returning id into updated_id;

  if updated_id is null then
    raise exception 'Diese offene Buchung wurde bereits geändert.' using errcode = 'P0002';
  end if;
  return updated_id;
end
$$;

revoke all on function public.clock_in(), public.clock_out(uuid, integer, text) from public, anon;
grant execute on function public.clock_in(), public.clock_out(uuid, integer, text) to authenticated;

-- 20261120020000_calendar_admin_reports.sql
alter table public.time_entries
  add column original_entry jsonb,
  add constraint time_entries_review_audit_check
    check (original_entry is null or (corrects_entry_id is not null and status = 'approved'));

create function private.assert_admin() returns void
language plpgsql stable set search_path = ''
as $$
begin
  if not private.is_admin() then
    raise exception 'Adminrechte erforderlich.' using errcode = '42501';
  end if;
end
$$;

create function public.review_correction(entry_id uuid, accept boolean) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  proposal public.time_entries%rowtype;
  original public.time_entries%rowtype;
begin
  perform private.assert_admin();
  select * into proposal from public.time_entries where id = entry_id;
  if not found then raise exception 'Antrag nicht gefunden.' using errcode = 'P0002'; end if;
  perform private.lock_user(proposal.user_id);
  select * into proposal from public.time_entries where id = entry_id and status = 'submitted' for update;
  if not found then raise exception 'Der Antrag wurde bereits entschieden.' using errcode = 'P0002'; end if;

  if accept then
    perform private.assert_unlocked(proposal.user_id, (proposal.started_at at time zone 'Europe/Berlin')::date,
      (proposal.ended_at at time zone 'Europe/Berlin')::date);
    if proposal.corrects_entry_id is not null then
      select * into original from public.time_entries
      where id = proposal.corrects_entry_id and user_id = proposal.user_id
        and status in ('open', 'recorded', 'approved') for update;
      if not found then raise exception 'Die ursprüngliche Buchung fehlt.' using errcode = 'P0002'; end if;
      perform private.assert_unlocked(original.user_id, (original.started_at at time zone 'Europe/Berlin')::date,
        (coalesce(original.ended_at, original.started_at) at time zone 'Europe/Berlin')::date);
      update public.time_entries
      set started_at = proposal.started_at, ended_at = proposal.ended_at,
          break_minutes = proposal.break_minutes, break_adjusted = proposal.break_adjusted,
          note = proposal.note, status = 'approved', approved_by = auth.uid()
      where id = original.id;
    end if;
  end if;

  update public.time_entries
  set status = case when accept then 'approved'::public.entry_status else 'rejected'::public.entry_status end,
      approved_by = auth.uid(),
      original_entry = case when original.id is not null then to_jsonb(original) end
  where id = entry_id;
end
$$;

create function public.resolve_open_entry(entry_id uuid, corrected_end timestamptz, reason text,
  adjusted_break integer default null) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  original public.time_entries%rowtype;
  settings public.company_settings%rowtype;
  proposal_id uuid;
begin
  perform private.assert_admin();
  select * into original from public.time_entries where id = entry_id;
  if not found then raise exception 'Buchung nicht gefunden.' using errcode = 'P0002'; end if;
  perform private.lock_user(original.user_id);
  select * into original from public.time_entries where id = entry_id and status = 'open' for update;
  if not found then raise exception 'Die Buchung wurde bereits geschlossen.' using errcode = 'P0002'; end if;
  select * into strict settings from public.company_settings where id = 1;
  insert into public.time_entries (user_id, started_at, ended_at, break_minutes, break_adjusted, note,
    status, correction_reason, corrects_entry_id)
  values (original.user_id, original.started_at, corrected_end,
    coalesce(adjusted_break, private.automatic_break(original.started_at, corrected_end,
      settings.auto_break_start, settings.auto_break_minutes)), adjusted_break is not null, original.note,
    'submitted', reason, original.id)
  returning id into proposal_id;
  perform public.review_correction(proposal_id, true);
end
$$;

create function public.review_absence(absence_id uuid, accept boolean) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  request public.absences%rowtype;
begin
  perform private.assert_admin();
  select * into request from public.absences where id = absence_id;
  if not found then raise exception 'Antrag nicht gefunden.' using errcode = 'P0002'; end if;
  perform private.lock_user(request.user_id);
  select * into request from public.absences where id = absence_id and status = 'submitted' for update;
  if not found then raise exception 'Der Antrag wurde bereits entschieden.' using errcode = 'P0002'; end if;
  if accept then perform private.assert_unlocked(request.user_id, request.start_date, request.end_date); end if;
  update public.absences
  set status = case when accept then 'approved'::public.absence_status else 'rejected'::public.absence_status end
  where id = absence_id;
end
$$;

create function public.record_absence(member_id uuid, kind public.absence_type, first_day date,
  last_day date, entry_note text default null) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  absence_id uuid;
begin
  perform private.assert_admin();
  perform private.lock_user(member_id);
  perform private.assert_unlocked(member_id, first_day, last_day);
  insert into public.absences (user_id, type, start_date, end_date, status, note)
  values (member_id, kind, first_day, last_day, 'approved', nullif(btrim(entry_note), ''))
  returning id into absence_id;
  return absence_id;
end
$$;

create function private.calculate_month(member_id uuid, first_day date)
returns public.monthly_summaries
language plpgsql stable set search_path = ''
as $$
declare
  result public.monthly_summaries%rowtype;
  monthly_hours numeric;
  next_day date := (first_day + interval '1 month')::date;
  last_month date := (first_day - interval '1 month')::date;
  first_at timestamptz := first_day::timestamp at time zone 'Europe/Berlin';
  next_at timestamptz := next_day::timestamp at time zone 'Europe/Berlin';
  target_days integer;
begin
  select p.weekly_hours into monthly_hours from public.profiles p where p.id = member_id;
  if not found then raise exception 'Profil nicht gefunden.' using errcode = 'P0002'; end if;

  result.user_id := member_id;
  result.year := extract(year from first_day);
  result.month := extract(month from first_day);
  result.is_locked := false;

  select coalesce(sum(floor(extract(epoch from (e.ended_at - e.started_at)) / 60) - e.break_minutes), 0),
         coalesce(sum(e.break_minutes), 0)
  into result.worked_minutes, result.break_minutes
  from public.time_entries e
  where e.user_id = member_id and e.started_at >= first_at and e.started_at < next_at
    and e.status in ('recorded','approved') and e.corrects_entry_id is null;

  select count(*) filter (where a.type is null or a.type = 'comp_time'),
         count(*) filter (where a.type = 'vacation'),
         count(*) filter (where a.type = 'sick'),
         count(*) filter (where a.type = 'comp_time')
  into target_days, result.vacation_days, result.sick_days, result.comp_time_days
  from generate_series(0, next_day - first_day - 1) as d(day_offset)
  left join public.absences a on a.user_id = member_id and a.status = 'approved'
    and first_day + d.day_offset between a.start_date and a.end_date
  where extract(isodow from first_day + d.day_offset) <= 5;

  result.target_minutes := round(target_days * monthly_hours * 60 / 5);
  select coalesce((select s.balance_minutes from public.monthly_summaries s
    where s.user_id = member_id and s.is_locked
      and s.year = extract(year from last_month) and s.month = extract(month from last_month)), 0)
  into result.carryover_minutes;
  result.balance_minutes := result.carryover_minutes + result.worked_minutes - result.target_minutes;
  return result;
end
$$;

create function public.read_monthly_report(member_id uuid, report_year integer, report_month integer)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  first_day date := make_date(report_year, report_month, 1);
  stored public.monthly_summaries%rowtype;
begin
  if not private.is_active_member() or (member_id is distinct from auth.uid() and not private.is_admin()) then
    raise exception 'Kein Zugriff auf diesen Bericht.' using errcode = '42501';
  end if;
  select * into stored from public.monthly_summaries s
  where s.user_id = member_id and s.year = report_year and s.month = report_month and s.is_locked;
  if found then return to_jsonb(stored); end if;
  return to_jsonb(private.calculate_month(member_id, first_day));
end
$$;

create function public.close_month(member_id uuid, report_year integer, report_month integer)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  first_day date := make_date(report_year, report_month, 1);
  next_day date := (first_day + interval '1 month')::date;
  result public.monthly_summaries%rowtype;
begin
  perform private.assert_admin();
  perform private.lock_user(member_id);

  select * into result from public.monthly_summaries s
  where s.user_id = member_id and s.year = report_year and s.month = report_month and s.is_locked;
  if found then return to_jsonb(result); end if;

  if next_day > (clock_timestamp() at time zone 'Europe/Berlin')::date then
    raise exception 'Ein Monat kann erst nach seinem Ende abgeschlossen werden.';
  end if;
  if exists (select from public.monthly_summaries s where s.user_id = member_id and s.is_locked
    and (s.year, s.month) > (report_year, report_month)) then
    raise exception 'Ein späterer Monat ist bereits abgeschlossen.';
  end if;
  if exists (select from public.monthly_summaries s where s.user_id = member_id and s.is_locked)
    and not exists (select from public.monthly_summaries s where s.user_id = member_id and s.is_locked
       and make_date(s.year,s.month,1) = (first_day - interval '1 month')::date) then
    raise exception 'Bitte zuerst den vorherigen Monat abschließen, damit der Übertrag vollständig ist.';
  end if;
  if exists (
    select from public.time_entries e
    left join public.time_entries original on original.id = e.corrects_entry_id
    where e.user_id = member_id and e.status in ('open','submitted')
      and ((e.started_at at time zone 'Europe/Berlin')::date < next_day
        and (e.ended_at is null or (e.ended_at at time zone 'Europe/Berlin')::date >= first_day)
        or ((original.started_at at time zone 'Europe/Berlin')::date < next_day
          and (original.ended_at is null or (original.ended_at at time zone 'Europe/Berlin')::date >= first_day)))
  ) or exists (
    select from public.absences a where a.user_id = member_id and a.status = 'submitted'
      and a.start_date < next_day and a.end_date >= first_day
  ) then
    raise exception 'Für diesen Monat gibt es offene Buchungen oder Anträge.';
  end if;

  result := private.calculate_month(member_id, first_day);
  insert into public.monthly_summaries (user_id, year, month, target_minutes, worked_minutes,
    break_minutes, balance_minutes, carryover_minutes, vacation_days, sick_days, comp_time_days,
    is_locked, closed_by, closed_at)
  values (result.user_id, result.year, result.month, result.target_minutes, result.worked_minutes,
    result.break_minutes, result.balance_minutes, result.carryover_minutes, result.vacation_days,
    result.sick_days, result.comp_time_days, true, auth.uid(), clock_timestamp())
  on conflict (user_id, year, month) do update
  set target_minutes = excluded.target_minutes, worked_minutes = excluded.worked_minutes,
    break_minutes = excluded.break_minutes, balance_minutes = excluded.balance_minutes,
    carryover_minutes = excluded.carryover_minutes, vacation_days = excluded.vacation_days,
    sick_days = excluded.sick_days, comp_time_days = excluded.comp_time_days, is_locked = true,
    closed_by = excluded.closed_by, closed_at = excluded.closed_at
  returning * into result;
  return to_jsonb(result);
end
$$;

revoke all on function private.assert_admin(), private.calculate_month(uuid, date) from public, anon, authenticated;
revoke all on function public.review_correction(uuid, boolean), public.resolve_open_entry(uuid, timestamptz, text, integer),
  public.review_absence(uuid, boolean),
  public.record_absence(uuid, public.absence_type, date, date, text),
  public.read_monthly_report(uuid, integer, integer), public.close_month(uuid, integer, integer)
from public, anon;
grant execute on function public.review_correction(uuid, boolean), public.resolve_open_entry(uuid, timestamptz, text, integer),
  public.review_absence(uuid, boolean),
  public.record_absence(uuid, public.absence_type, date, date, text),
  public.read_monthly_report(uuid, integer, integer), public.close_month(uuid, integer, integer)
to authenticated;

-- 20261120030000_live_breaks.sql
create table private.clock_breaks (
  entry_id uuid primary key references public.time_entries(id) on delete cascade,
  paused_at timestamptz,
  finished_seconds bigint not null default 0 check (finished_seconds >= 0)
);
revoke all on private.clock_breaks from public, anon, authenticated;

create function public.clock_break_status() returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object('entry_id', b.entry_id, 'paused_at', b.paused_at, 'finished_seconds', b.finished_seconds)
  from private.clock_breaks b join public.time_entries e on e.id = b.entry_id
  where e.user_id = auth.uid() and e.status = 'open' and private.is_active_member()
$$;

create function public.set_clock_break(entry_id uuid, start_break boolean) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  member_id uuid := auth.uid();
  started timestamptz;
  changed_at timestamptz;
begin
  if not private.is_active_member() then
    raise exception 'Ein aktives Profil ist erforderlich.' using errcode = '42501';
  end if;

  perform private.lock_user(member_id);
  select e.started_at into started from public.time_entries e
  where e.id = set_clock_break.entry_id and e.user_id = member_id and e.status = 'open'
  for update;
  if not found then
    raise exception 'Diese offene Buchung wurde bereits geändert.' using errcode = 'P0002';
  end if;
  changed_at := clock_timestamp();
  perform private.assert_unlocked(member_id, (started at time zone 'Europe/Berlin')::date,
    (changed_at at time zone 'Europe/Berlin')::date);

  if start_break then
    insert into private.clock_breaks (entry_id, paused_at)
    values (set_clock_break.entry_id, changed_at)
    on conflict on constraint clock_breaks_pkey do update
    set paused_at = coalesce(private.clock_breaks.paused_at, excluded.paused_at);
  else
    update private.clock_breaks b
    set finished_seconds = b.finished_seconds + greatest(0, floor(extract(epoch from changed_at - b.paused_at)))::bigint,
        paused_at = null
    where b.entry_id = set_clock_break.entry_id and b.paused_at is not null;
  end if;
end
$$;

create or replace function public.clock_out(entry_id uuid, adjusted_break integer default null, entry_note text default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  member_id uuid := auth.uid();
  started timestamptz;
  stopped timestamptz;
  tracked private.clock_breaks%rowtype;
  paused_seconds bigint;
  effective_break integer := adjusted_break;
begin
  if not private.is_active_member() then
    raise exception 'Ein aktives Profil ist erforderlich.' using errcode = '42501';
  end if;

  perform private.lock_user(member_id);
  select e.started_at into started from public.time_entries e
  where e.id = clock_out.entry_id and e.user_id = member_id and e.status = 'open' for update;
  if not found then
    raise exception 'Diese offene Buchung wurde bereits geändert.' using errcode = 'P0002';
  end if;
  stopped := clock_timestamp();
  perform private.assert_unlocked(member_id, (started at time zone 'Europe/Berlin')::date,
    (stopped at time zone 'Europe/Berlin')::date);

  select * into tracked from private.clock_breaks b where b.entry_id = clock_out.entry_id;
  if found then
    paused_seconds := tracked.finished_seconds;
    if tracked.paused_at is not null then
      paused_seconds := paused_seconds + greatest(0, floor(extract(epoch from stopped - tracked.paused_at)))::bigint;
    end if;
    if effective_break is null then effective_break := (paused_seconds / 60)::integer; end if;
    update private.clock_breaks b set finished_seconds = paused_seconds, paused_at = null
    where b.entry_id = clock_out.entry_id;
  end if;

  update public.time_entries e
  set ended_at = stopped,
      status = 'recorded',
      break_adjusted = effective_break is not null,
      break_minutes = coalesce(effective_break, 0),
      note = coalesce(nullif(btrim(entry_note), ''), e.note)
  where e.id = clock_out.entry_id;
  return clock_out.entry_id;
end
$$;

create function public.admin_paused_members() returns uuid[]
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform private.assert_admin();
  return coalesce((select array_agg(e.user_id)
    from private.clock_breaks b join public.time_entries e on e.id = b.entry_id
    where b.paused_at is not null and e.status = 'open'), '{}'::uuid[]);
end
$$;

revoke all on function public.admin_paused_members(), public.clock_break_status(), public.set_clock_break(uuid, boolean),
  public.clock_out(uuid, integer, text) from public, anon;
grant execute on function public.admin_paused_members(), public.clock_break_status(), public.set_clock_break(uuid, boolean),
  public.clock_out(uuid, integer, text) to authenticated;

-- 20261120040000_team_and_daily_reports.sql
alter table public.profiles add column department text
  check (department in ('management','sales','dispatch','accounting'));

create table public.team_groups (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 1 and 60)
);
create unique index team_groups_unique_name on public.team_groups (lower(btrim(name)));
create table public.team_group_members (
  group_id uuid not null references public.team_groups(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  primary key (group_id, user_id)
);
alter table public.team_groups enable row level security;
alter table public.team_group_members enable row level security;
revoke all on public.team_groups, public.team_group_members from public, anon, authenticated;
grant select, insert, update, delete on public.team_groups to authenticated;
grant select on public.team_group_members to authenticated;
create policy team_groups_read on public.team_groups for select to authenticated using (private.is_active_member());
create policy team_groups_admin on public.team_groups for all to authenticated using (private.is_admin()) with check (private.is_admin());
create policy membership_admin on public.team_group_members for select to authenticated using (private.is_admin());

create function public.save_staff_details(member_id uuid, member_name text, hours numeric,
  leave_days numeric, active boolean, member_department text, group_ids uuid[])
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform private.assert_admin();
  perform private.lock_user(member_id);
  update public.profiles set full_name = btrim(member_name), weekly_hours = hours,
    annual_leave_days = leave_days, is_active = case when member_id = auth.uid() then true else active end,
    department = nullif(member_department, '')
  where id = member_id;
  if not found then raise exception 'Profil nicht gefunden.' using errcode = 'P0002'; end if;
  delete from public.team_group_members where user_id = member_id;
  insert into public.team_group_members (group_id, user_id)
  select distinct g.id, member_id from unnest(group_ids) g(id);
end
$$;

create function public.team_calendar_details(first_day date, last_day date)
returns table (id uuid, user_id uuid, full_name text, type public.absence_type,
  start_date date, end_date date, status public.absence_status, department text, group_ids uuid[])
language sql stable security definer set search_path = ''
as $$
  select a.id, a.user_id, a.full_name, a.type, a.start_date, a.end_date, a.status, p.department,
    array(select m.group_id from public.team_group_members m where m.user_id = a.user_id order by m.group_id)
  from public.team_calendar(first_day, last_day) a join public.profiles p on p.id = a.user_id
$$;

-- Gregorian Easter Sunday for nationwide German holidays.
create function private.easter_sunday(y integer) returns date
language sql immutable strict set search_path = ''
as $$
  with part as (select y % 19 as a, y / 100 as b, y % 100 as c),
  next_part as (select *, (19*a + b - b/4 - (b-(b+8)/25+1)/3 + 15) % 30 as h from part),
  adjusted as (select *, (32 + 2*(b%4) + 2*(c/4) - h - c%4) % 7 as l from next_part),
  result as (select h+l-7*((a+11*h+22*l)/451)+114 as n from adjusted)
  select make_date(y, n/31, n%31+1) from result
$$;

create function private.german_holiday(day date) returns text
language sql immutable strict set search_path = ''
as $$
  select case
    when extract(month from day)=1 and extract(day from day)=1 then 'Neujahr'
    when extract(month from day)=5 and extract(day from day)=1 then 'Tag der Arbeit'
    when extract(month from day)=10 and extract(day from day)=3 then 'Tag der Deutschen Einheit'
    when extract(month from day)=12 and extract(day from day)=25 then '1. Weihnachtstag'
    when extract(month from day)=12 and extract(day from day)=26 then '2. Weihnachtstag'
    else case day - private.easter_sunday(extract(year from day)::integer)
      when -2 then 'Karfreitag' when 1 then 'Ostermontag'
      when 39 then 'Christi Himmelfahrt' when 50 then 'Pfingstmontag'
    end
  end
$$;

create function public.company_holidays(first_day date, last_day date)
returns table (day date, name text)
language sql stable security definer set search_path = ''
as $$
  select first_day + d.offset_days, holiday.name
  from generate_series(0, least(last_day - first_day, 366)) d(offset_days)
  cross join lateral (select private.german_holiday(first_day + d.offset_days) as name) holiday
  where private.is_active_member() and holiday.name is not null
$$;

alter table public.monthly_summaries add column daily_breakdown jsonb;

create function private.daily_month(member_id uuid, first_day date, use_holidays boolean)
returns table (day date, target_minutes integer, worked_minutes integer, break_minutes integer,
  difference_minutes integer, absence_type public.absence_type, holiday text)
language sql stable set search_path = ''
as $$
  with dates as (
    select first_day + d.offset_days as day
    from generate_series(0, (first_day + interval '1 month')::date - first_day - 1) d(offset_days)
  ), entries as (
    select (e.started_at at time zone 'Europe/Berlin')::date as day,
      sum(floor(extract(epoch from (e.ended_at-e.started_at))/60)-e.break_minutes)::integer as worked,
      sum(e.break_minutes)::integer as breaks
    from public.time_entries e
    where e.user_id=member_id and e.started_at >= (first_day::timestamp at time zone 'Europe/Berlin')
      and e.started_at < ((first_day + interval '1 month') at time zone 'Europe/Berlin')
      and e.status in ('recorded','approved') and e.corrects_entry_id is null
    group by 1
  ), base as (
    select d.day, p.weekly_hours, coalesce(e.worked,0) as worked, coalesce(e.breaks,0) as breaks,
      case when extract(isodow from d.day)<=5 and h.holiday is null then a.type end as absence, h.holiday,
      case when extract(isodow from d.day)<=5 and h.holiday is null and (a.type is null or a.type='comp_time')
        then 1 else 0 end as target_day
    from dates d cross join public.profiles p
    left join entries e on e.day=d.day
    left join public.absences a on a.user_id=member_id and a.status='approved' and d.day between a.start_date and a.end_date
    cross join lateral (select case when use_holidays then private.german_holiday(d.day) end as holiday) h
    where p.id=member_id
  ), cumulative as (
    select *, sum(target_day) over (order by day) as eligible_days from base
  ), minutes as (
    select *, (round(eligible_days*weekly_hours*12)-round((eligible_days-target_day)*weekly_hours*12))::integer as target
    from cumulative
  )
  select day, target, worked, breaks, worked-target, absence, holiday from minutes order by day
$$;

create or replace function private.calculate_month(member_id uuid, first_day date)
returns public.monthly_summaries
language plpgsql stable set search_path = ''
as $$
declare
  result public.monthly_summaries%rowtype;
  last_month date := (first_day - interval '1 month')::date;
begin
  if not exists (select from public.profiles where id=member_id) then
    raise exception 'Profil nicht gefunden.' using errcode='P0002';
  end if;
  result.user_id := member_id;
  result.year := extract(year from first_day);
  result.month := extract(month from first_day);
  result.is_locked := false;
  select sum(d.target_minutes), sum(d.worked_minutes), sum(d.break_minutes),
    count(*) filter (where d.absence_type='vacation'), count(*) filter (where d.absence_type='sick'),
    count(*) filter (where d.absence_type='comp_time')
  into result.target_minutes, result.worked_minutes, result.break_minutes,
    result.vacation_days, result.sick_days, result.comp_time_days
  from private.daily_month(member_id, first_day, true) d;
  select coalesce((select s.balance_minutes from public.monthly_summaries s
    where s.user_id = member_id and s.is_locked
      and s.year = extract(year from last_month) and s.month = extract(month from last_month)), 0)
  into result.carryover_minutes;
  result.balance_minutes := result.carryover_minutes + result.worked_minutes - result.target_minutes;
  return result;
end
$$;

create function private.snapshot_daily_month() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.is_locked and (tg_op = 'INSERT' or not old.is_locked) then
    select jsonb_agg(to_jsonb(d) order by d.day) into new.daily_breakdown
    from private.daily_month(new.user_id, make_date(new.year,new.month,1), true) d;
  elsif tg_op = 'UPDATE' then
    new.daily_breakdown := old.daily_breakdown;
  end if;
  return new;
end
$$;
create trigger snapshot_daily_month before insert or update on public.monthly_summaries
for each row execute function private.snapshot_daily_month();

create function public.read_daily_report(member_id uuid, report_year integer, report_month integer)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  stored boolean;
  report jsonb;
  rows jsonb;
begin
  report := public.read_monthly_report(member_id, report_year, report_month);
  rows := report->'daily_breakdown';
  stored := rows is not null and rows <> 'null'::jsonb;
  if not stored then
    select jsonb_agg(to_jsonb(d) order by d.day) into rows
    from private.daily_month(member_id, make_date(report_year, report_month, 1),
      not (report->>'is_locked')::boolean) d;
  end if;
  return jsonb_build_object('days', rows, 'archived', stored,
    'reconstructed', (report->>'is_locked')::boolean and not stored);
end
$$;

create function public.read_annual_leave(report_year integer)
returns numeric language sql stable security definer set search_path = ''
as $$
  select p.annual_leave_days - (
    select count(*)
    from public.absences a
    cross join lateral generate_series(0,
      least(a.end_date, make_date(report_year,12,31)) - greatest(a.start_date, make_date(report_year,1,1))
    ) days(offset_days)
    cross join lateral (select greatest(a.start_date, make_date(report_year,1,1)) + days.offset_days as day) d
    where a.user_id=p.id and a.status='approved' and a.type='vacation'
      and a.start_date <= make_date(report_year,12,31) and a.end_date >= make_date(report_year,1,1)
      and extract(isodow from d.day)<=5 and private.german_holiday(d.day) is null
  )
  from public.profiles p where p.id=auth.uid() and p.is_active
$$;

revoke all on function private.easter_sunday(integer), private.german_holiday(date),
  private.daily_month(uuid,date,boolean), private.snapshot_daily_month() from public, anon, authenticated;
revoke all on function public.company_holidays(date,date), public.team_calendar_details(date,date),
  public.save_staff_details(uuid,text,numeric,numeric,boolean,text,uuid[]),
  public.read_daily_report(uuid,integer,integer), public.read_annual_leave(integer) from public, anon;
grant execute on function public.company_holidays(date,date), public.team_calendar_details(date,date),
  public.save_staff_details(uuid,text,numeric,numeric,boolean,text,uuid[]),
  public.read_daily_report(uuid,integer,integer), public.read_annual_leave(integer) to authenticated;

-- 20261120050000_dashboard_and_current_reports.sql
create or replace function private.calculate_month(member_id uuid, first_day date)
returns public.monthly_summaries
language plpgsql stable set search_path = ''
as $$
declare
  result public.monthly_summaries%rowtype;
  last_month date := (first_day - interval '1 month')::date;
begin
  if not exists (select from public.profiles where id=member_id) then
    raise exception 'Profil nicht gefunden.' using errcode='P0002';
  end if;
  result.user_id := member_id;
  result.year := extract(year from first_day);
  result.month := extract(month from first_day);
  result.is_locked := false;
  select coalesce(sum(d.target_minutes),0), coalesce(sum(d.worked_minutes),0), coalesce(sum(d.break_minutes),0),
    count(*) filter (where d.absence_type='vacation'), count(*) filter (where d.absence_type='sick'),
    count(*) filter (where d.absence_type='comp_time')
  into result.target_minutes, result.worked_minutes, result.break_minutes,
    result.vacation_days, result.sick_days, result.comp_time_days
  from private.daily_month(member_id, first_day, true) d
  where d.day <= (statement_timestamp() at time zone 'Europe/Berlin')::date;
  select coalesce((select s.balance_minutes from public.monthly_summaries s
    where s.user_id = member_id and s.is_locked
      and s.year = extract(year from last_month) and s.month = extract(month from last_month)), 0)
  into result.carryover_minutes;
  result.balance_minutes := result.carryover_minutes + result.worked_minutes - result.target_minutes;
  return result;
end
$$;

create or replace function public.read_daily_report(member_id uuid, report_year integer, report_month integer)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  stored boolean;
  report jsonb;
  rows jsonb;
begin
  report := public.read_monthly_report(member_id, report_year, report_month);
  rows := report->'daily_breakdown';
  stored := rows is not null and rows <> 'null'::jsonb;
  if not stored then
    select jsonb_agg(to_jsonb(d) order by d.day) into rows
    from private.daily_month(member_id, make_date(report_year, report_month, 1),
      not (report->>'is_locked')::boolean) d
    where (report->>'is_locked')::boolean or d.day <= (statement_timestamp() at time zone 'Europe/Berlin')::date;
  end if;
  return jsonb_build_object('days', coalesce(rows, '[]'::jsonb), 'archived', stored,
    'reconstructed', (report->>'is_locked')::boolean and not stored);
end
$$;

create or replace function public.team_calendar(first_day date, last_day date)
returns table (
  id uuid, user_id uuid, full_name text, type public.absence_type,
  start_date date, end_date date, status public.absence_status
)
language sql stable security definer set search_path = ''
as $$
  select a.id, a.user_id, p.full_name, a.type, a.start_date, a.end_date, a.status
  from public.absences a join public.profiles p on p.id = a.user_id
  where first_day <= last_day and a.start_date <= last_day and a.end_date >= first_day
    and a.status = 'approved' and private.is_active_member()
    and (private.is_admin() or a.user_id = auth.uid() or
      a.type <> 'sick')
$$;

alter table public.time_entries add column decided_at timestamptz;
alter table public.absences add column decided_at timestamptz;

create function private.stamp_request_decision() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.decided_at := null;
  elsif old.status = 'submitted' and new.status in ('approved','rejected') then
    new.decided_at := clock_timestamp();
  else
    new.decided_at := old.decided_at;
  end if;
  return new;
end
$$;

create trigger stamp_request_decision before insert or update on public.time_entries
for each row execute function private.stamp_request_decision();
create trigger stamp_request_decision before insert or update on public.absences
for each row execute function private.stamp_request_decision();
revoke all on function private.stamp_request_decision() from public, anon, authenticated;

create function public.admin_pause_details()
returns table (user_id uuid, paused_at timestamptz)
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform private.assert_admin();
  return query select e.user_id, b.paused_at
  from private.clock_breaks b join public.time_entries e on e.id = b.entry_id
  where b.paused_at is not null and e.status='open';
end
$$;

revoke all on function public.admin_pause_details() from public, anon;
grant execute on function public.admin_pause_details() to authenticated;

-- 20261120060000_departments_and_break_history.sql
alter table public.profiles add column automatic_lunch_break boolean not null default true;

create table private.clock_break_intervals (
  id uuid primary key default gen_random_uuid(),
  entry_id uuid not null references public.time_entries(id) on delete cascade,
  started_at timestamptz not null,
  ended_at timestamptz check (ended_at >= started_at)
);
create unique index one_running_clock_break_interval on private.clock_break_intervals(entry_id) where ended_at is null;
revoke all on private.clock_break_intervals from public, anon, authenticated;

insert into private.clock_break_intervals (entry_id, started_at)
select b.entry_id, b.paused_at from private.clock_breaks b
join public.time_entries e on e.id=b.entry_id
where b.paused_at is not null and e.status='open';

create function private.capture_clock_break_interval() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and old.paused_at is not null and new.paused_at is null then
    update private.clock_break_intervals b
    set ended_at = greatest(b.started_at, clock_timestamp())
    where b.entry_id = new.entry_id and b.ended_at is null;
  elsif new.paused_at is not null and (tg_op = 'INSERT' or old.paused_at is null) then
    insert into private.clock_break_intervals (entry_id, started_at)
    values (new.entry_id, new.paused_at)
    on conflict (entry_id) where ended_at is null do nothing;
  end if;
  return new;
end
$$;
create trigger capture_clock_break_interval after insert or update on private.clock_breaks
for each row execute function private.capture_clock_break_interval();

create function private.finish_clock_break_after_entry() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if old.status = 'open' and new.status <> 'open' then
    update private.clock_break_intervals b
    set ended_at = greatest(b.started_at, least(new.ended_at, clock_timestamp()))
    where b.entry_id = old.id and b.ended_at is null;
  end if;
  return new;
end
$$;
create trigger finish_clock_break_after_entry after update on public.time_entries
for each row execute function private.finish_clock_break_after_entry();

create function public.read_shift_breaks(member_id uuid, first_day date, last_day date)
returns table (id uuid, entry_id uuid, user_id uuid, started_at timestamptz, ended_at timestamptz)
language plpgsql stable security definer set search_path = ''
as $$
declare
  first_at timestamptz := first_day::timestamp at time zone 'Europe/Berlin';
  end_at timestamptz := (last_day + 1)::timestamp at time zone 'Europe/Berlin';
begin
  if not private.is_active_member() or (member_id is distinct from auth.uid() and not private.is_admin()) then
    raise exception 'Kein Zugriff auf diese Pausenzeiten.' using errcode = '42501';
  end if;
  if last_day < first_day or last_day-first_day > 366 then
    raise exception 'Ungültiger Zeitraum.';
  end if;
  return query select b.id, b.entry_id, e.user_id, b.started_at, b.ended_at
  from private.clock_break_intervals b join public.time_entries e on e.id=b.entry_id
  where (member_id is null or member_id=e.user_id)
    and ((b.started_at < end_at and (b.ended_at is null or b.ended_at >= first_at))
      or (e.started_at >= first_at and e.started_at < end_at))
  order by b.started_at;
end
$$;

create function public.update_staff_settings(member_id uuid, member_name text, hours numeric,
  leave_days numeric, active boolean, member_department text, automatic_lunch boolean)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform private.assert_admin();
  perform private.lock_user(member_id);
  update public.profiles set full_name=btrim(member_name), weekly_hours=hours, annual_leave_days=leave_days,
    is_active=case when member_id=auth.uid() then true else active end,
    department=nullif(member_department,''), automatic_lunch_break=automatic_lunch
  where id=member_id;
  if not found then raise exception 'Profil nicht gefunden.' using errcode='P0002'; end if;
end
$$;

create function private.automatic_break_for_member(member_id uuid, started timestamptz, ended timestamptz,
  lunch_start time, lunch_minutes integer) returns integer
language sql stable set search_path = ''
as $$
  select case when (select p.automatic_lunch_break from public.profiles p where p.id=member_id)
    then private.automatic_break(started, ended, lunch_start, lunch_minutes) else 0 end
$$;

create or replace function private.guard_time_entry() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  settings public.company_settings%rowtype;
  original public.time_entries%rowtype;
begin
  perform private.lock_user(case when tg_op = 'DELETE' then old.user_id else new.user_id end);
  if tg_op = 'DELETE' then return old; end if;
  if auth.uid() is null or private.is_admin() then
    if new.status in ('recorded','submitted') and not new.break_adjusted then
      select * into strict settings from public.company_settings where id = 1;
      new.break_minutes := private.automatic_break_for_member(
        new.user_id, new.started_at, new.ended_at, settings.auto_break_start, settings.auto_break_minutes);
    end if;
    return new;
  end if;

  if tg_op = 'UPDATE' then
    if new.id <> old.id or new.user_id <> old.user_id or new.created_at <> old.created_at
      or new.corrects_entry_id is distinct from old.corrects_entry_id then
      raise exception 'Geschützte Buchungsfelder.' using errcode = '42501';
    end if;
    perform private.assert_unlocked(old.user_id, (old.started_at at time zone 'Europe/Berlin')::date,
      (coalesce(old.ended_at, old.started_at) at time zone 'Europe/Berlin')::date);
  else
    new.created_at := statement_timestamp();
  end if;

  if new.approved_by is not null then
    raise exception 'Freigaben erfordern Adminrechte.' using errcode = '42501';
  end if;

  if tg_op = 'INSERT' and new.status = 'open' then
    new.started_at := clock_timestamp();
    new.ended_at := null;
    new.break_minutes := 0;
    new.break_adjusted := false;
  elsif tg_op = 'UPDATE' and old.status = 'open' and new.status = 'recorded' then
    new.started_at := old.started_at;
    new.ended_at := clock_timestamp();
  elsif new.status <> 'submitted' or (tg_op = 'UPDATE' and old.status <> 'submitted') then
    raise exception 'Historische Zeiten erfordern einen Korrekturantrag.' using errcode = '42501';
  end if;

  if new.corrects_entry_id is not null then
    select * into original from public.time_entries
    where id = new.corrects_entry_id and user_id = new.user_id
      and status in ('open', 'recorded', 'approved');
    if not found then
      raise exception 'Ungültiger Bezug für den Korrekturantrag.' using errcode = '42501';
    end if;
    perform private.assert_unlocked(original.user_id, (original.started_at at time zone 'Europe/Berlin')::date,
      (coalesce(original.ended_at, original.started_at) at time zone 'Europe/Berlin')::date);
  end if;

  if new.ended_at is not null and not new.break_adjusted then
    select * into strict settings from public.company_settings where id = 1;
    new.break_minutes := private.automatic_break_for_member(
      new.user_id, new.started_at, new.ended_at, settings.auto_break_start, settings.auto_break_minutes);
  end if;

  perform private.assert_unlocked(new.user_id, (new.started_at at time zone 'Europe/Berlin')::date,
    (coalesce(new.ended_at, new.started_at) at time zone 'Europe/Berlin')::date);
  return new;
end
$$;

create or replace function public.resolve_open_entry(entry_id uuid, corrected_end timestamptz, reason text,
  adjusted_break integer default null) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  original public.time_entries%rowtype;
  settings public.company_settings%rowtype;
  proposal_id uuid;
begin
  perform private.assert_admin();
  select * into original from public.time_entries where id = entry_id;
  if not found then raise exception 'Buchung nicht gefunden.' using errcode = 'P0002'; end if;
  perform private.lock_user(original.user_id);
  select * into original from public.time_entries where id = entry_id and status = 'open' for update;
  if not found then raise exception 'Die Buchung wurde bereits geschlossen.' using errcode = 'P0002'; end if;
  select * into strict settings from public.company_settings where id = 1;
  insert into public.time_entries (user_id, started_at, ended_at, break_minutes, break_adjusted, note,
    status, correction_reason, corrects_entry_id)
  values (original.user_id, original.started_at, corrected_end,
    coalesce(adjusted_break, private.automatic_break_for_member(original.user_id, original.started_at, corrected_end,
      settings.auto_break_start, settings.auto_break_minutes)), adjusted_break is not null, original.note,
    'submitted', reason, original.id)
  returning id into proposal_id;
  perform public.review_correction(proposal_id, true);
end
$$;

revoke all on function private.capture_clock_break_interval(), private.finish_clock_break_after_entry(),
  private.automatic_break_for_member(uuid,timestamptz,timestamptz,time,integer) from public, anon, authenticated;
revoke all on function public.read_shift_breaks(uuid,date,date),
  public.update_staff_settings(uuid,text,numeric,numeric,boolean,text,boolean) from public, anon;
grant execute on function public.read_shift_breaks(uuid,date,date),
  public.update_staff_settings(uuid,text,numeric,numeric,boolean,text,boolean) to authenticated;

create function public.read_member_annual_leave(member_id uuid, report_year integer)
returns numeric language sql stable security definer set search_path = ''
as $$
  select p.annual_leave_days - (
    select count(*)
    from public.absences a
    cross join lateral generate_series(0,
      least(a.end_date, make_date(report_year,12,31)) - greatest(a.start_date, make_date(report_year,1,1))
    ) days(offset_days)
    cross join lateral (select greatest(a.start_date, make_date(report_year,1,1)) + days.offset_days as day) d
    where a.user_id=p.id and a.status='approved' and a.type='vacation'
      and a.start_date <= make_date(report_year,12,31) and a.end_date >= make_date(report_year,1,1)
      and extract(isodow from d.day)<=5 and private.german_holiday(d.day) is null
  )
  from public.profiles p where p.id=member_id and private.is_active_member() and (member_id=auth.uid() or private.is_admin())
$$;

revoke all on function public.read_member_annual_leave(uuid,integer) from public, anon;
grant execute on function public.read_member_annual_leave(uuid,integer) to authenticated;

commit;
