begin;

alter table public.company_settings
  add column time_tracking_start_date date check (isfinite(time_tracking_start_date));

update public.company_settings
set time_tracking_start_date = date '2026-11-24'
where id = 1;

create or replace function private.daily_month(member_id uuid, first_day date, use_holidays boolean)
returns table (day date, target_minutes integer, worked_minutes integer, break_minutes integer,
  difference_minutes integer, absence_type public.absence_type, holiday text)
language sql stable set search_path = ''
as $$
  with period as (
    select greatest(first_day, (select s.time_tracking_start_date from public.company_settings s where s.id = 1)) as start_day,
      (first_day + interval '1 month')::date as end_day
  ), dates as (
    select p.start_day + d.offset_days as day
    from period p
    cross join lateral generate_series(0, p.end_day - p.start_day - 1) d(offset_days)
  ), entries as (
    select (e.started_at at time zone 'Europe/Berlin')::date as day,
      sum(floor(extract(epoch from (e.ended_at-e.started_at))/60)-e.break_minutes)::integer as worked,
      sum(e.break_minutes)::integer as breaks
    from public.time_entries e cross join period p
    where e.user_id=member_id and e.started_at >= (p.start_day::timestamp at time zone 'Europe/Berlin')
      and e.started_at < (p.end_day::timestamp at time zone 'Europe/Berlin')
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
  select coalesce(sum(d.target_minutes),0), coalesce(sum(d.worked_minutes),0), coalesce(sum(d.break_minutes),0),
    count(*) filter (where d.absence_type='vacation'), count(*) filter (where d.absence_type='sick'),
    count(*) filter (where d.absence_type='comp_time')
  into result.target_minutes, result.worked_minutes, result.break_minutes,
    result.vacation_days, result.sick_days, result.comp_time_days
  from private.daily_month(member_id, first_day, true) d
  where d.day <= (statement_timestamp() at time zone 'Europe/Berlin')::date;
  select coalesce((select s.balance_minutes from public.monthly_summaries s
    where s.user_id = member_id and s.is_locked
      and s.year = extract(year from last_month) and s.month = extract(month from last_month)
      and not exists (select from public.company_settings c where c.id = 1
        and c.time_tracking_start_date >= first_day)), 0)
  into result.carryover_minutes;
  result.balance_minutes := result.carryover_minutes + result.worked_minutes - result.target_minutes;
  return result;
end
$$;

create or replace function public.close_month(member_id uuid, report_year integer, report_month integer)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  first_day date := make_date(report_year, report_month, 1);
  next_day date := (first_day + interval '1 month')::date;
  tracking_start date;
  effective_first_day date;
  result public.monthly_summaries%rowtype;
begin
  perform private.assert_admin();
  perform private.lock_user(member_id);

  select * into result from public.monthly_summaries s
  where s.user_id = member_id and s.year = report_year and s.month = report_month and s.is_locked;
  if found then return to_jsonb(result); end if;

  select coalesce(time_tracking_start_date, '-infinity'::date) into strict tracking_start
  from public.company_settings where id = 1;
  effective_first_day := greatest(first_day, tracking_start);

  if next_day <= tracking_start then
    raise exception 'Dieser Monat liegt vor dem Start der Zeiterfassung.';
  end if;
  if next_day > (clock_timestamp() at time zone 'Europe/Berlin')::date then
    raise exception 'Ein Monat kann erst nach seinem Ende abgeschlossen werden.';
  end if;
  if exists (select from public.monthly_summaries s where s.user_id = member_id and s.is_locked
    and (s.year, s.month) > (report_year, report_month)) then
    raise exception 'Ein späterer Monat ist bereits abgeschlossen.';
  end if;
  if exists (select from public.monthly_summaries s where s.user_id = member_id and s.is_locked
    and (make_date(s.year,s.month,1) + interval '1 month')::date > tracking_start)
    and not exists (select from public.monthly_summaries s where s.user_id = member_id and s.is_locked
       and make_date(s.year,s.month,1) = (first_day - interval '1 month')::date) then
    raise exception 'Bitte zuerst den vorherigen Monat abschließen, damit der Übertrag vollständig ist.';
  end if;
  if exists (
    select from public.time_entries e
    left join public.time_entries original on original.id = e.corrects_entry_id
    where e.user_id = member_id and e.status in ('open','submitted')
      and (((e.started_at at time zone 'Europe/Berlin')::date < next_day
        and (e.started_at at time zone 'Europe/Berlin')::date >= tracking_start
        and (e.ended_at is null or (e.ended_at at time zone 'Europe/Berlin')::date >= effective_first_day))
        or ((original.started_at at time zone 'Europe/Berlin')::date < next_day
          and (original.started_at at time zone 'Europe/Berlin')::date >= tracking_start
          and (original.ended_at is null or (original.ended_at at time zone 'Europe/Berlin')::date >= effective_first_day)))
  ) or exists (
    select from public.absences a where a.user_id = member_id and a.status = 'submitted'
      and a.start_date < next_day and a.end_date >= effective_first_day
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

commit;
