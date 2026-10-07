-- F27/F42: authoritative activation plans and coherent exam-goal lifecycle.
begin;

-- A paused goal is a lifecycle state, not an active scheduling priority.
alter table public.deck_exams drop constraint if exists deck_exams_status_check;
alter table public.deck_exams add constraint deck_exams_status_check
  check (status in ('active', 'paused', 'completed', 'cancelled'));

create or replace function public.touch_deck_exam_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_deck_exams_updated_at on public.deck_exams;
create trigger trg_deck_exams_updated_at
before update on public.deck_exams
for each row execute function public.touch_deck_exam_updated_at();

-- All editable goal fields and lifecycle transitions are checked and committed
-- together. RLS still protects the returned row for the authenticated owner.
create or replace function public.update_deck_exam(
  p_exam_id uuid,
  p_exam_name text default null,
  p_deck_id uuid default null,
  p_target_date date default null,
  p_priority_level public.exam_priority_level default null,
  p_status text default null
)
returns public.deck_exams
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_exam public.deck_exams;
  v_status text := p_status;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode = 'P0001'; end if;
  select * into v_exam
  from public.deck_exams
  where id = p_exam_id and user_id = auth.uid()
  for update;
  if not found then raise exception 'DECK_EXAM_NOT_FOUND' using errcode = 'P0001'; end if;

  if p_exam_name is not null and char_length(btrim(p_exam_name)) = 0 then
    raise exception 'INVALID_EXAM_NAME' using errcode = 'P0001';
  end if;
  if p_exam_name is not null and char_length(btrim(p_exam_name)) > 200 then
    raise exception 'INVALID_EXAM_NAME' using errcode = 'P0001';
  end if;
  if p_deck_id is not null and not exists (
    select 1 from public.decks d
    where d.id = p_deck_id and d.user_id = auth.uid() and d.deleted_at is null
  ) then
    raise exception 'DECK_NOT_FOUND' using errcode = 'P0001';
  end if;
  if p_target_date is not null and p_target_date < current_date then
    raise exception 'INVALID_TARGET_DATE' using errcode = 'P0001';
  end if;
  if v_status is not null and v_status not in ('active', 'paused', 'completed', 'cancelled') then
    raise exception 'INVALID_DECK_EXAM_STATUS' using errcode = 'P0001';
  end if;

  update public.deck_exams
  set exam_name = coalesce(btrim(p_exam_name), exam_name),
      deck_id = coalesce(p_deck_id, deck_id),
      target_date = coalesce(p_target_date, target_date),
      priority_level = coalesce(p_priority_level, priority_level),
      status = coalesce(v_status, status)
  where id = p_exam_id and user_id = auth.uid()
  returning * into v_exam;
  return v_exam;
end;
$$;
revoke execute on function public.update_deck_exam(uuid, text, uuid, date, public.exam_priority_level, text) from public, anon;
grant execute on function public.update_deck_exam(uuid, text, uuid, date, public.exam_priority_level, text) to authenticated;

-- The queue reads the current row on every call. A changed deadline therefore
-- changes urgency immediately, while both explicit paused state and legacy
-- paused priority are excluded from scheduling.
create or replace function public.get_due_cards_with_exam_schedule(
  p_deck_id uuid default null,
  p_limit integer default 50
)
returns table (
  card_id uuid,
  deck_id uuid,
  fields jsonb,
  state public.card_state,
  due_at timestamptz,
  interval_days numeric,
  exam_id uuid,
  exam_name text,
  target_date date,
  days_remaining integer,
  scheduling_factor numeric
)
language sql
security invoker
stable
set search_path = public
as $$
  with recursive deck_tree as (
    select d.id
    from public.decks d
    where d.user_id = auth.uid()
      and d.deleted_at is null
      and (p_deck_id is null or d.id = p_deck_id)
    union all
    select child.id
    from public.decks child
    join deck_tree parent on child.parent_deck_id = parent.id
    where child.user_id = auth.uid() and child.deleted_at is null
  ),
  settings as (
    select coalesce(
      (select new_cards_per_day from public.study_settings where user_id = auth.uid()),
      20
    ) as new_limit
  ),
  studied_new_today as (
    select coalesce(
      (select new_cards_studied from public.daily_statistics
       where user_id = auth.uid() and stat_date = current_date),
      0
    ) as done
  ),
  active_exams as (
    select distinct on (e.deck_id)
      e.id as exam_id, e.deck_id, e.exam_name, e.target_date, e.priority_level,
      (e.target_date - current_date)::integer as days_remaining
    from public.deck_exams e
    where e.user_id = auth.uid()
      and e.status = 'active'
      and e.priority_level <> 'paused'
      and exists (select 1 from deck_tree dt where dt.id = e.deck_id)
    order by e.deck_id, e.target_date asc, e.created_at asc
  ),
  candidates as (
    select c.id as card_id, c.deck_id, c.fields, ls.state, ls.due_at, ls.interval_days,
      ae.exam_id, ae.exam_name, ae.target_date, ae.days_remaining,
      case
        when ae.exam_id is null then 1.0::numeric
        when ae.days_remaining <= 0 then 2.0::numeric
        when ae.days_remaining <= 7 then 1.5::numeric
        when ae.days_remaining <= 30 then 1.2::numeric
        else 1.0::numeric
      end as scheduling_factor,
      (ls.state <> 'new') as is_due_review,
      c.created_at
    from public.card_learning_state ls
    join public.cards c on c.id = ls.card_id
    left join active_exams ae on ae.deck_id = c.deck_id
    where ls.user_id = auth.uid()
      and ls.is_suspended = false
      and c.deleted_at is null and c.is_archived=false and exists(select 1 from public.decks active_deck where active_deck.id=c.deck_id and active_deck.deleted_at is null and active_deck.is_archived=false)
      and (p_deck_id is null or exists (select 1 from deck_tree dt where dt.id = c.deck_id))
      and (
        (ls.state <> 'new' and ls.due_at <= now())
        or ls.state = 'new'
      )
  ),
  limited_new as (
    select * from candidates
    where is_due_review = false
    order by created_at asc
    limit greatest((select new_limit from settings) - (select done from studied_new_today), 0)
  ),
  queue as (
    select * from candidates where is_due_review
    union all
    select * from limited_new
  )
  select q.card_id, q.deck_id, q.fields, q.state, q.due_at, q.interval_days,
    q.exam_id, q.exam_name, q.target_date, q.days_remaining, q.scheduling_factor
  from queue q
  order by
    case when q.days_remaining is not null and q.days_remaining <= 0 then 0
         when q.days_remaining is not null and q.days_remaining <= 7 then 1
         when q.is_due_review then 2 else 3 end,
    (q.due_at - ((q.scheduling_factor - 1) * interval '1 day')) asc,
    q.created_at asc
  limit least(greatest(coalesce(p_limit, 50), 1), 5000);
$$;
revoke execute on function public.get_due_cards_with_exam_schedule(uuid, integer) from public, anon;
grant execute on function public.get_due_cards_with_exam_schedule(uuid, integer) to authenticated;

comment on function public.update_deck_exam(uuid, text, uuid, date, public.exam_priority_level, text)
is 'F42: atomically edits an owned study goal and its lifecycle state.';
comment on function public.get_due_cards_with_exam_schedule(uuid, integer)
is 'F42: current active, non-paused goals drive urgency; deadline edits apply on the next queue read.';

commit;
