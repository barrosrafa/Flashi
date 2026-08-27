-- Flashi 0024: gamification, exam scheduling and Socratic leech remediation.
-- Additive and rerunnable. Existing AI ingestion, image occlusion and note
-- reference objects from 0021 are intentionally not recreated here.

begin;

do $$
begin
  create type public.exam_priority_level as enum (
    'exam_urgent', 'currently_studying', 'maintaining', 'paused'
  );
exception when duplicate_object then null;
end $$;

-- ---------------------------------------------------------------------------
-- Gamification.
-- ---------------------------------------------------------------------------
create table if not exists public.user_gamification_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  xp_total integer not null default 0 check (xp_total >= 0),
  level_current integer not null default 1 check (level_current >= 1),
  streak_days_count integer not null default 0 check (streak_days_count >= 0),
  highest_streak_count integer not null default 0 check (highest_streak_count >= 0),
  usn bigint not null default nextval('public.sync_usn_seq'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_user_gamification_profiles_usn
  on public.user_gamification_profiles (user_id, usn);

create table if not exists public.badges_definition (
  id uuid primary key default gen_random_uuid(),
  code_name text not null unique,
  display_name text not null,
  description text,
  icon_url text,
  xp_requirement integer not null default 0 check (xp_requirement >= 0),
  created_at timestamptz not null default now()
);

create table if not exists public.user_badges (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  badge_id uuid not null references public.badges_definition(id) on delete cascade,
  unlocked_at timestamptz not null default now(),
  usn bigint not null default nextval('public.sync_usn_seq'),
  unique (user_id, badge_id)
);
create index if not exists idx_user_badges_user_usn
  on public.user_badges (user_id, usn);

create or replace function public.add_user_xp(p_user_id uuid, p_xp_amount integer)
returns public.user_gamification_profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile public.user_gamification_profiles;
  v_new_xp integer;
begin
  if auth.uid() is null or auth.uid() <> p_user_id then
    raise exception 'Only the authenticated owner can add XP';
  end if;
  if p_xp_amount is null or p_xp_amount < 0 then
    raise exception 'p_xp_amount must be a non-negative integer';
  end if;

  insert into public.user_gamification_profiles (user_id)
  values (p_user_id)
  on conflict (user_id) do nothing;

  select * into v_profile
  from public.user_gamification_profiles
  where user_id = p_user_id
  for update;

  v_new_xp := v_profile.xp_total + p_xp_amount;
  update public.user_gamification_profiles
  set xp_total = v_new_xp,
      level_current = greatest(1, floor(sqrt(v_new_xp::numeric / 100.0))::integer + 1),
      updated_at = now()
  where user_id = p_user_id
  returning * into v_profile;

  return v_profile;
end;
$$;

-- ---------------------------------------------------------------------------
-- Exam scheduler.
-- ---------------------------------------------------------------------------
create table if not exists public.deck_exams (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  deck_id uuid not null references public.decks(id) on delete cascade,
  exam_name text not null,
  target_date date not null,
  priority_level public.exam_priority_level not null default 'currently_studying',
  status text not null default 'active' check (status in ('active', 'completed', 'cancelled')),
  usn bigint not null default nextval('public.sync_usn_seq'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_deck_exams_user_target
  on public.deck_exams (user_id, target_date, status);
create index if not exists idx_deck_exams_deck_target
  on public.deck_exams (deck_id, target_date) where status = 'active';

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
      and c.deleted_at is null
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

-- ---------------------------------------------------------------------------
-- Socratic remediation for leeches.
-- ---------------------------------------------------------------------------
create table if not exists public.socratic_remediation_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  card_id uuid not null references public.cards(id) on delete cascade,
  status public.job_status_type not null default 'queued',
  chat_history jsonb not null default '[]'::jsonb,
  usn bigint not null default nextval('public.sync_usn_seq'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_socratic_sessions_user_status
  on public.socratic_remediation_sessions (user_id, status, created_at desc);
create index if not exists idx_socratic_sessions_card
  on public.socratic_remediation_sessions (card_id, created_at desc);

create or replace function public.check_card_leech_for_socratic()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.lapses >= 4 and coalesce(old.lapses, 0) < 4 then
    new.is_suspended := true;
    insert into public.socratic_remediation_sessions (user_id, card_id, status)
    select new.user_id, new.card_id, 'queued'
    where not exists (
      select 1 from public.socratic_remediation_sessions s
      where s.user_id = new.user_id and s.card_id = new.card_id
        and s.status in ('queued', 'processing')
    );
  end if;
  return new;
end;
$$;

drop trigger if exists trg_card_learning_state_socratic_leech on public.card_learning_state;
create trigger trg_card_learning_state_socratic_leech
before update of lapses on public.card_learning_state
for each row execute function public.check_card_leech_for_socratic();

create or replace function public.resolve_socratic_remediation(p_session_id uuid)
returns public.socratic_remediation_sessions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.socratic_remediation_sessions;
begin
  select * into v_session
  from public.socratic_remediation_sessions
  where id = p_session_id and user_id = auth.uid()
  for update;
  if not found then raise exception 'Socratic remediation session not found'; end if;
  if v_session.status = 'completed' then return v_session; end if;

  update public.card_learning_state
  set is_suspended = false, lapses = 0, due_at = now(), updated_at = now()
  where user_id = v_session.user_id and card_id = v_session.card_id;

  update public.socratic_remediation_sessions
  set status = 'completed', updated_at = now()
  where id = p_session_id
  returning * into v_session;
  return v_session;
end;
$$;

-- ---------------------------------------------------------------------------
-- USN, tombstones and incremental sync.
-- ---------------------------------------------------------------------------
alter table public.graves drop constraint if exists graves_entity_type_check;
alter table public.graves add constraint graves_entity_type_check check (entity_type in (
  'deck', 'card', 'note', 'card_template', 'tag', 'card_media', 'card_learning_state', 'review_log',
  'study_settings', 'user_deck_settings', 'daily_statistics', 'note_card_definition', 'note_cloze_deletion',
  'fsrs_optimization_run', 'card_tag', 'ai_ingestion_job', 'note_image_occlusion_box', 'note_reference',
  'user_gamification_profile', 'user_badge', 'deck_exam', 'socratic_remediation_session'
));

do $$
declare v_table text; v_entity text; v_pair text;
begin
  foreach v_pair in array array[
    'user_gamification_profiles:user_gamification_profile',
    'user_badges:user_badge',
    'deck_exams:deck_exam',
    'socratic_remediation_sessions:socratic_remediation_session'
  ]::text[] loop
    v_table := split_part(v_pair, ':', 1); v_entity := split_part(v_pair, ':', 2);
    execute format('drop trigger if exists %I on public.%I', 'trg_' || v_table || '_sync_usn', v_table);
    execute format('create trigger %I before insert or update on public.%I for each row execute function public.assign_sync_usn()', 'trg_' || v_table || '_sync_usn', v_table);
    execute format('drop trigger if exists %I on public.%I', 'trg_' || v_table || '_sync_grave', v_table);
    execute format('create trigger %I after update or delete on public.%I for each row execute function public.record_sync_grave(%L)', 'trg_' || v_table || '_sync_grave', v_table, v_entity);
  end loop;
end $$;

create or replace function public.get_incremental_sync(p_after_usn bigint default 0, p_limit integer default 500)
returns table (entity_type text, entity_key text, usn bigint, is_deleted boolean, payload jsonb)
language sql security invoker stable set search_path = public as $$
  with changes (entity_type, entity_key, usn, is_deleted, payload) as (
    select 'deck'::text, d.id::text, d.usn, false, to_jsonb(d) from public.decks d where d.deleted_at is null and d.usn > p_after_usn
    union all select 'note', n.id::text, n.usn, false, to_jsonb(n) from public.notes n where n.deleted_at is null and n.usn > p_after_usn
    union all select 'card', c.id::text, c.usn, false, to_jsonb(c) from public.cards c where c.deleted_at is null and c.usn > p_after_usn
    union all select 'card_media', m.id::text, m.usn, false, to_jsonb(m) from public.card_media m where m.usn > p_after_usn
    union all select 'card_learning_state', s.id::text, s.usn, false, to_jsonb(s) from public.card_learning_state s where s.usn > p_after_usn
    union all select 'review_log', r.id::text, r.usn, false, to_jsonb(r) from public.review_logs r where r.usn > p_after_usn
    union all select 'tag', t.id::text, t.usn, false, to_jsonb(t) from public.tags t where t.usn > p_after_usn
    union all select 'card_template', t.id::text, t.usn, false, to_jsonb(t) from public.card_templates t where t.user_id = auth.uid() and t.usn > p_after_usn
    union all select 'study_settings', s.user_id::text, s.usn, false, to_jsonb(s) from public.study_settings s where s.user_id = auth.uid() and s.usn > p_after_usn
    union all select 'user_deck_settings', s.user_id::text || ':' || s.deck_id::text, s.usn, false, to_jsonb(s) from public.user_deck_settings s where s.user_id = auth.uid() and s.usn > p_after_usn
    union all select 'daily_statistics', s.user_id::text || ':' || s.stat_date::text, s.usn, false, to_jsonb(s) from public.daily_statistics s where s.user_id = auth.uid() and s.usn > p_after_usn
    union all select 'note_card_definition', d.id::text, d.usn, false, to_jsonb(d) from public.note_card_definitions d where d.usn > p_after_usn
    union all select 'note_cloze_deletion', d.id::text, d.usn, false, to_jsonb(d) from public.note_cloze_deletions d where d.usn > p_after_usn
    union all select 'fsrs_optimization_run', o.id::text, o.usn, false, to_jsonb(o) from public.fsrs_optimization_runs o where o.user_id = auth.uid() and o.usn > p_after_usn
    union all select 'ai_ingestion_job', j.id::text, j.usn, false, to_jsonb(j) from public.ai_ingestion_jobs j where j.user_id = auth.uid() and j.deleted_at is null and j.usn > p_after_usn
    union all select 'note_image_occlusion_box', b.id::text, b.usn, false, to_jsonb(b) from public.note_image_occlusion_boxes b join public.notes n on n.id = b.note_id where n.user_id = auth.uid() and b.usn > p_after_usn
    union all select 'note_reference', r.id::text, r.usn, false, to_jsonb(r) from public.note_references r join public.notes n on n.id = r.source_note_id where n.user_id = auth.uid() and r.usn > p_after_usn
    union all select 'user_gamification_profile', g.user_id::text, g.usn, false, to_jsonb(g) from public.user_gamification_profiles g where g.user_id = auth.uid() and g.usn > p_after_usn
    union all select 'user_badge', b.id::text, b.usn, false, to_jsonb(b) from public.user_badges b where b.user_id = auth.uid() and b.usn > p_after_usn
    union all select 'deck_exam', e.id::text, e.usn, false, to_jsonb(e) from public.deck_exams e where e.user_id = auth.uid() and e.usn > p_after_usn
    union all select 'socratic_remediation_session', s.id::text, s.usn, false, to_jsonb(s) from public.socratic_remediation_sessions s where s.user_id = auth.uid() and s.usn > p_after_usn
    union all select g.entity_type, g.entity_key, g.usn, true, jsonb_build_object('entity_type', g.entity_type, 'entity_key', g.entity_key, 'deleted_at', g.deleted_at) from public.graves g where g.usn > p_after_usn and g.user_id = auth.uid()
  )
  select entity_type, entity_key, usn, is_deleted, payload from changes order by usn asc limit least(greatest(p_limit, 1), 5000);
$$;

-- ---------------------------------------------------------------------------
-- RLS and public API grants.
-- ---------------------------------------------------------------------------
alter table public.user_gamification_profiles enable row level security;
drop policy if exists user_gamification_profiles_owner_select on public.user_gamification_profiles;
create policy user_gamification_profiles_owner_select on public.user_gamification_profiles for select using (auth.uid() = user_id);
drop policy if exists user_gamification_profiles_owner_insert on public.user_gamification_profiles;
create policy user_gamification_profiles_owner_insert on public.user_gamification_profiles for insert with check (auth.uid() = user_id);
drop policy if exists user_gamification_profiles_owner_update on public.user_gamification_profiles;
create policy user_gamification_profiles_owner_update on public.user_gamification_profiles for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists user_gamification_profiles_owner_delete on public.user_gamification_profiles;
create policy user_gamification_profiles_owner_delete on public.user_gamification_profiles for delete using (auth.uid() = user_id);

alter table public.badges_definition enable row level security;
drop policy if exists badges_definition_public_select on public.badges_definition;
create policy badges_definition_public_select on public.badges_definition for select using (true);

alter table public.user_badges enable row level security;
drop policy if exists user_badges_owner_select on public.user_badges;
create policy user_badges_owner_select on public.user_badges for select using (auth.uid() = user_id);
drop policy if exists user_badges_owner_insert on public.user_badges;
create policy user_badges_owner_insert on public.user_badges for insert with check (auth.uid() = user_id);
drop policy if exists user_badges_owner_update on public.user_badges;
create policy user_badges_owner_update on public.user_badges for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists user_badges_owner_delete on public.user_badges;
create policy user_badges_owner_delete on public.user_badges for delete using (auth.uid() = user_id);

alter table public.deck_exams enable row level security;
drop policy if exists deck_exams_owner_select on public.deck_exams;
create policy deck_exams_owner_select on public.deck_exams for select using (auth.uid() = user_id);
drop policy if exists deck_exams_owner_insert on public.deck_exams;
create policy deck_exams_owner_insert on public.deck_exams for insert with check (auth.uid() = user_id);
drop policy if exists deck_exams_owner_update on public.deck_exams;
create policy deck_exams_owner_update on public.deck_exams for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists deck_exams_owner_delete on public.deck_exams;
create policy deck_exams_owner_delete on public.deck_exams for delete using (auth.uid() = user_id);

alter table public.socratic_remediation_sessions enable row level security;
drop policy if exists socratic_sessions_owner_select on public.socratic_remediation_sessions;
create policy socratic_sessions_owner_select on public.socratic_remediation_sessions for select using (auth.uid() = user_id);
drop policy if exists socratic_sessions_owner_insert on public.socratic_remediation_sessions;
create policy socratic_sessions_owner_insert on public.socratic_remediation_sessions for insert with check (auth.uid() = user_id);
drop policy if exists socratic_sessions_owner_update on public.socratic_remediation_sessions;
create policy socratic_sessions_owner_update on public.socratic_remediation_sessions for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists socratic_sessions_owner_delete on public.socratic_remediation_sessions;
create policy socratic_sessions_owner_delete on public.socratic_remediation_sessions for delete using (auth.uid() = user_id);

revoke execute on function public.add_user_xp(uuid, integer) from public, anon;
grant execute on function public.add_user_xp(uuid, integer) to authenticated;
revoke execute on function public.get_due_cards_with_exam_schedule(uuid, integer) from public, anon;
grant execute on function public.get_due_cards_with_exam_schedule(uuid, integer) to authenticated;
revoke execute on function public.resolve_socratic_remediation(uuid) from public, anon;
grant execute on function public.resolve_socratic_remediation(uuid) to authenticated;
revoke execute on function public.check_card_leech_for_socratic() from public, anon, authenticated;

comment on table public.user_gamification_profiles is 'Per-user XP, level and streak counters.';
comment on table public.deck_exams is 'User-owned exam dates used to prioritize due-card queues, including recursive subdecks.';
comment on table public.socratic_remediation_sessions is 'Socratic remediation jobs automatically queued for leech cards with four or more lapses.';
comment on function public.add_user_xp(uuid, integer) is 'Atomically adds XP for the authenticated owner and recalculates level.';
comment on function public.get_due_cards_with_exam_schedule(uuid, integer) is 'Returns the bounded due/new-card queue with exam urgency and scheduling factor.';
comment on function public.resolve_socratic_remediation(uuid) is 'Completes an owned Socratic session and unsuspends/resets its card.';

commit;
