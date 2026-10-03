-- Flashi schema snapshot: 04_functions_triggers_rls.sql
-- Triggers, RPCs, hardening and all row-level security policies.
-- Generated from the v1 baseline; historical sources remain in ../migrations_archive/.
-- Apply strictly in lexical order.


-- ================= SOURCE 0008_triggers_functions.sql =================
-- 0008_triggers_functions.sql

-- Generic updated_at maintenance.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_profiles_updated_at on public.profiles;
create trigger trg_profiles_updated_at before update on public.profiles
  for each row execute function public.set_updated_at();

drop trigger if exists trg_decks_updated_at on public.decks;
create trigger trg_decks_updated_at before update on public.decks
  for each row execute function public.set_updated_at();

drop trigger if exists trg_card_templates_updated_at on public.card_templates;
create trigger trg_card_templates_updated_at before update on public.card_templates
  for each row execute function public.set_updated_at();

drop trigger if exists trg_cards_updated_at on public.cards;
create trigger trg_cards_updated_at before update on public.cards
  for each row execute function public.set_updated_at();

drop trigger if exists trg_learning_state_updated_at on public.card_learning_state;
create trigger trg_learning_state_updated_at before update on public.card_learning_state
  for each row execute function public.set_updated_at();

drop trigger if exists trg_study_settings_updated_at on public.study_settings;
create trigger trg_study_settings_updated_at before update on public.study_settings
  for each row execute function public.set_updated_at();

drop trigger if exists trg_user_deck_settings_updated_at on public.user_deck_settings;
create trigger trg_user_deck_settings_updated_at before update on public.user_deck_settings
  for each row execute function public.set_updated_at();

-- Provisions profile + default study settings whenever a new Supabase Auth user is created.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id) values (new.id)
  on conflict (id) do nothing;

  insert into public.study_settings (user_id) values (new.id)
  on conflict (user_id) do nothing;

  return new;
end;
$$;

drop trigger if exists trg_auth_user_created on auth.users;
create trigger trg_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Defense-in-depth: review_logs must be immutable even against direct
-- SQL (RLS in 0009 already blocks it at the API level; this blocks it
-- at the table level too, e.g. against service_role misuse).
create or replace function public.prevent_review_log_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception 'review_logs is append-only: % is not allowed', tg_op;
end;
$$;

drop trigger if exists trg_review_logs_no_update on public.review_logs;
create trigger trg_review_logs_no_update
  before update or delete on public.review_logs
  for each row execute function public.prevent_review_log_mutation();


-- ================= SOURCE 0009_rls_policies.sql =================
-- 0009_rls_policies.sql
-- Row Level Security for every user-owned table. Never rely on the
-- frontend for authorization -- these policies are the actual boundary.

alter table public.profiles enable row level security;
alter table public.decks enable row level security;
alter table public.deck_collaborators enable row level security;
alter table public.tags enable row level security;
alter table public.card_templates enable row level security;
alter table public.cards enable row level security;
alter table public.card_tags enable row level security;
alter table public.card_media enable row level security;
alter table public.card_learning_state enable row level security;
alter table public.review_logs enable row level security;
alter table public.study_settings enable row level security;
alter table public.user_deck_settings enable row level security;
alter table public.daily_statistics enable row level security;

-- profiles ------------------------------------------------------------
drop policy if exists profiles_self on public.profiles;
create policy profiles_self on public.profiles
  for all using (auth.uid() = id) with check (auth.uid() = id);

-- decks -----------------------------------------------------------------
-- Deliberately NO delete policy: end users can only soft-delete
-- (update deleted_at via soft_delete_deck(), see 0010). Hard deletes
-- are only possible via service_role, which bypasses RLS entirely.
drop policy if exists decks_select on public.decks;
create policy decks_select on public.decks
  for select using (auth.uid() = user_id);

drop policy if exists decks_insert on public.decks;
create policy decks_insert on public.decks
  for insert with check (auth.uid() = user_id);

drop policy if exists decks_update on public.decks;
create policy decks_update on public.decks
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists decks_public_read on public.decks;
create policy decks_public_read on public.decks
  for select using (visibility = 'public' and deleted_at is null);

drop policy if exists decks_shared_read on public.decks;
create policy decks_shared_read on public.decks
  for select using (
    exists (
      select 1 from public.deck_collaborators dc
      where dc.deck_id = decks.id and dc.user_id = auth.uid()
    )
  );

-- deck_collaborators ------------------------------------------------------
drop policy if exists deck_collaborators_owner_manage on public.deck_collaborators;
create policy deck_collaborators_owner_manage on public.deck_collaborators
  for all using (
    exists (select 1 from public.decks d where d.id = deck_collaborators.deck_id and d.user_id = auth.uid())
  ) with check (
    exists (select 1 from public.decks d where d.id = deck_collaborators.deck_id and d.user_id = auth.uid())
  );

drop policy if exists deck_collaborators_self_read on public.deck_collaborators;
create policy deck_collaborators_self_read on public.deck_collaborators
  for select using (auth.uid() = user_id);

-- tags --------------------------------------------------------------------
drop policy if exists tags_owner on public.tags;
create policy tags_owner on public.tags
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- card_templates ------------------------------------------------------------
drop policy if exists templates_owner on public.card_templates;
create policy templates_owner on public.card_templates
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists templates_system_read on public.card_templates;
create policy templates_system_read on public.card_templates
  for select using (is_system = true);

-- cards ---------------------------------------------------------------------
-- Same no-delete-for-end-users pattern as decks.
drop policy if exists cards_select on public.cards;
create policy cards_select on public.cards
  for select using (auth.uid() = user_id);

drop policy if exists cards_insert on public.cards;
create policy cards_insert on public.cards
  for insert with check (auth.uid() = user_id);

drop policy if exists cards_update on public.cards;
create policy cards_update on public.cards
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists cards_public_read on public.cards;
create policy cards_public_read on public.cards
  for select using (
    exists (
      select 1 from public.decks d
      where d.id = cards.deck_id and d.visibility = 'public' and d.deleted_at is null
    )
  );

drop policy if exists cards_shared_read on public.cards;
create policy cards_shared_read on public.cards
  for select using (
    exists (
      select 1 from public.deck_collaborators dc
      where dc.deck_id = cards.deck_id and dc.user_id = auth.uid()
    )
  );

-- card_tags (ownership derived from the card) --------------------------------
drop policy if exists card_tags_owner on public.card_tags;
create policy card_tags_owner on public.card_tags
  for all using (
    exists (select 1 from public.cards c where c.id = card_tags.card_id and c.user_id = auth.uid())
  ) with check (
    exists (select 1 from public.cards c where c.id = card_tags.card_id and c.user_id = auth.uid())
  );

-- card_media ------------------------------------------------------------------
drop policy if exists card_media_owner on public.card_media;
create policy card_media_owner on public.card_media
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- card_learning_state -----------------------------------------------------------
-- Always strictly private to the studier, even on public/shared decks:
-- your SRS progress on someone else's deck is never someone else's business.
drop policy if exists learning_state_owner on public.card_learning_state;
create policy learning_state_owner on public.card_learning_state
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- review_logs ---------------------------------------------------------------------
-- INSERT + SELECT only. No UPDATE/DELETE policy exists at all, so those
-- operations are denied outright for authenticated users (belt-and-suspenders
-- with the trigger in 0008).
drop policy if exists review_logs_select on public.review_logs;
create policy review_logs_select on public.review_logs
  for select using (auth.uid() = user_id);

drop policy if exists review_logs_insert on public.review_logs;
create policy review_logs_insert on public.review_logs
  for insert with check (auth.uid() = user_id);

-- study_settings ------------------------------------------------------------------
drop policy if exists study_settings_owner on public.study_settings;
create policy study_settings_owner on public.study_settings
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- user_deck_settings ----------------------------------------------------------------
drop policy if exists user_deck_settings_owner on public.user_deck_settings;
create policy user_deck_settings_owner on public.user_deck_settings
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- daily_statistics --------------------------------------------------------------------
drop policy if exists daily_stats_owner on public.daily_statistics;
create policy daily_stats_owner on public.daily_statistics
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);


-- ================= SOURCE 0010_views_rpc.sql =================
-- 0010_views_rpc.sql

-- Recursive deck hierarchy, useful for breadcrumbs / tree rendering.
create or replace view public.v_deck_tree as
with recursive tree as (
  select id, user_id, parent_deck_id, name, 1 as depth, name::text as path
  from public.decks
  where parent_deck_id is null and deleted_at is null
  union all
  select d.id, d.user_id, d.parent_deck_id, d.name, t.depth + 1, t.path || ' / ' || d.name
  from public.decks d
  join tree t on d.parent_deck_id = t.id
  where d.deleted_at is null
)
select * from tree;

-- ---------------------------------------------------------------------------
-- get_due_cards: THE core query -- "cards this user needs to study now".
-- Runs as the caller (security invoker), so RLS still applies; a user can
-- never fetch another user's due cards through this function.
-- Mixes due review/learning/relearning cards with new cards, capped by the
-- user's daily new-card quota (based on today's daily_statistics row).
-- ---------------------------------------------------------------------------
create or replace function public.get_due_cards(
  p_deck_id uuid default null,
  p_limit integer default 50
)
returns table (
  card_id uuid,
  deck_id uuid,
  fields jsonb,
  state public.card_state,
  due_at timestamptz,
  interval_days numeric
)
language sql
security invoker
stable
as $$
  with settings as (
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
  due as (
    select c.id as card_id, c.deck_id, c.fields, ls.state, ls.due_at, ls.interval_days
    from public.card_learning_state ls
    join public.cards c on c.id = ls.card_id
    where ls.user_id = auth.uid()
      and ls.is_suspended = false
      and ls.state <> 'new'
      and ls.due_at <= now()
      and c.deleted_at is null
      and (p_deck_id is null or c.deck_id = p_deck_id)
  ),
  new_cards as (
    select c.id as card_id, c.deck_id, c.fields, ls.state, ls.due_at, ls.interval_days
    from public.card_learning_state ls
    join public.cards c on c.id = ls.card_id
    where ls.user_id = auth.uid()
      and ls.is_suspended = false
      and ls.state = 'new'
      and c.deleted_at is null
      and (p_deck_id is null or c.deck_id = p_deck_id)
    order by c.created_at asc
    limit greatest((select new_limit from settings) - (select done from studied_new_today), 0)
  )
  select * from due
  union all
  select * from new_cards
  order by due_at asc
  limit p_limit;
$$;

-- ---------------------------------------------------------------------------
-- record_review: atomically writes one review. The SM-2/FSRS math itself
-- is computed by the app/edge-function layer and passed in as arguments --
-- this function's only job is to persist review_logs + card_learning_state +
-- daily_statistics consistently in a single transaction.
-- ---------------------------------------------------------------------------
create or replace function public.record_review(
  p_card_id uuid,
  p_rating public.review_rating,
  p_time_spent_ms integer,
  p_new_state public.card_state,
  p_new_interval_days numeric,
  p_new_due_at timestamptz,
  p_new_ease_factor numeric default null,
  p_new_stability numeric default null,
  p_new_difficulty numeric default null,
  p_algorithm public.srs_algorithm default 'fsrs',
  p_device_id text default null,
  p_session_id uuid default null
)
returns void
language plpgsql
security invoker
as $$
declare
  v_prev public.card_learning_state%rowtype;
begin
  select * into v_prev
  from public.card_learning_state
  where user_id = auth.uid() and card_id = p_card_id
  for update;

  if not found then
    raise exception 'No learning state for card % / current user', p_card_id;
  end if;

  insert into public.review_logs (
    user_id, card_id, rating, time_spent_ms,
    prev_state, new_state, prev_interval_days, new_interval_days,
    prev_due_at, new_due_at, prev_ease_factor, new_ease_factor,
    prev_stability, new_stability, prev_difficulty, new_difficulty,
    algorithm, device_id, session_id
  ) values (
    auth.uid(), p_card_id, p_rating, p_time_spent_ms,
    v_prev.state, p_new_state, v_prev.interval_days, p_new_interval_days,
    v_prev.due_at, p_new_due_at, v_prev.ease_factor, p_new_ease_factor,
    v_prev.stability, p_new_stability, v_prev.difficulty, p_new_difficulty,
    p_algorithm, p_device_id, p_session_id
  );

  update public.card_learning_state set
    state = p_new_state,
    due_at = p_new_due_at,
    interval_days = p_new_interval_days,
    ease_factor = coalesce(p_new_ease_factor, ease_factor),
    stability = coalesce(p_new_stability, stability),
    difficulty = coalesce(p_new_difficulty, difficulty),
    reps = reps + 1,
    lapses = lapses + (case when p_rating = 'again' then 1 else 0 end),
    last_reviewed_at = now(),
    algorithm = p_algorithm
  where user_id = auth.uid() and card_id = p_card_id;

  insert into public.daily_statistics (
    user_id, stat_date, cards_studied, new_cards_studied,
    reviews_count, correct_count, incorrect_count, time_studied_ms
  ) values (
    auth.uid(), current_date, 1,
    case when v_prev.state = 'new' then 1 else 0 end,
    1,
    case when p_rating in ('good', 'easy') then 1 else 0 end,
    case when p_rating in ('again', 'hard') then 1 else 0 end,
    coalesce(p_time_spent_ms, 0)
  )
  on conflict (user_id, stat_date) do update set
    cards_studied = public.daily_statistics.cards_studied + 1,
    new_cards_studied = public.daily_statistics.new_cards_studied +
      (case when v_prev.state = 'new' then 1 else 0 end),
    reviews_count = public.daily_statistics.reviews_count + 1,
    correct_count = public.daily_statistics.correct_count +
      (case when p_rating in ('good', 'easy') then 1 else 0 end),
    incorrect_count = public.daily_statistics.incorrect_count +
      (case when p_rating in ('again', 'hard') then 1 else 0 end),
    time_studied_ms = public.daily_statistics.time_studied_ms + coalesce(p_time_spent_ms, 0),
    updated_at = now();
end;
$$;

-- Computed on the fly from daily_statistics rather than stored, so it can
-- never drift out of sync with the underlying data.
create or replace function public.get_current_streak()
returns integer
language sql
security invoker
stable
as $$
  with days as (
    select stat_date,
           stat_date - (row_number() over (order by stat_date desc))::int as grp
    from public.daily_statistics
    where user_id = auth.uid() and cards_studied > 0
  )
  select count(*)::int
  from days
  where grp = (select grp from days order by stat_date desc limit 1);
$$;

-- Cascading soft delete. Postgres FK ON DELETE CASCADE only fires on a real
-- DELETE, not an UPDATE -- so soft-deleting a deck's children has to be done
-- explicitly here rather than relying on the FK.
create or replace function public.soft_delete_deck(p_deck_id uuid)
returns void
language plpgsql
security invoker
as $$
begin
  update public.decks
  set deleted_at = now()
  where id = p_deck_id and user_id = auth.uid() and deleted_at is null;

  update public.decks
  set deleted_at = now()
  where parent_deck_id = p_deck_id and user_id = auth.uid() and deleted_at is null;

  update public.cards
  set deleted_at = now()
  where deck_id = p_deck_id and user_id = auth.uid() and deleted_at is null;
end;
$$;


-- ================= SOURCE 0015_hardening_workers_contracts.sql =================
-- Flashi 0015: hardening for FSRS retries, semantic workers, media integrity
-- and user-scoped incremental synchronization.
--
-- This migration keeps the existing 0014 function signatures compatible while
-- adding an idempotent review entry point for offline clients and workers.

-- ---------------------------------------------------------------------------
-- Integrity metadata and idempotency keys.
-- ---------------------------------------------------------------------------
alter table public.notes
  add column if not exists embedding_content_hash text;

alter table public.card_media
  add column if not exists sha256_hash text;

alter table public.review_logs
  add column if not exists client_review_id uuid;

DO $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'notes_embedding_content_hash_check'
      and conrelid = 'public.notes'::regclass
  ) then
    alter table public.notes add constraint notes_embedding_content_hash_check
      check (
        embedding_content_hash is null
        or embedding_content_hash ~ '^[0-9a-fA-F]{64}$'
      );
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'card_media_sha256_hash_check'
      and conrelid = 'public.card_media'::regclass
  ) then
    alter table public.card_media add constraint card_media_sha256_hash_check
      check (sha256_hash is null or sha256_hash ~ '^[0-9a-fA-F]{64}$');
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'card_media_storage_path_owner_check'
      and conrelid = 'public.card_media'::regclass
  ) then
    alter table public.card_media add constraint card_media_storage_path_owner_check
      check (storage_path like user_id::text || '/%');
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'review_logs_time_spent_nonnegative_check'
      and conrelid = 'public.review_logs'::regclass
  ) then
    alter table public.review_logs add constraint review_logs_time_spent_nonnegative_check
      check (time_spent_ms is null or time_spent_ms >= 0);
  end if;
end $$;

create unique index if not exists review_logs_user_client_review_id
  on public.review_logs (user_id, client_review_id)
  where client_review_id is not null;

create index if not exists idx_review_logs_user_algorithm_date
  on public.review_logs (user_id, algorithm, reviewed_at asc);

create index if not exists idx_card_media_user_sha256
  on public.card_media (user_id, sha256_hash)
  where sha256_hash is not null;

create index if not exists idx_learning_state_state_due
  on public.card_learning_state (user_id, state, due_at)
  where is_suspended = false;

create index if not exists idx_cards_user_deck_active
  on public.cards (user_id, deck_id, id)
  where deleted_at is null;

-- ---------------------------------------------------------------------------
-- Idempotent FSRS persistence.
-- The client_review_id is generated by the client and reused on retries. The
-- server remains the authority for user_id, reviewed_at and USN.
-- ---------------------------------------------------------------------------
create or replace function public.record_review_fsrs6_idempotent(
  p_card_id uuid,
  p_rating public.review_rating,
  p_time_spent_ms integer,
  p_new_state public.card_state,
  p_new_interval_days numeric,
  p_new_due_at timestamptz,
  p_fsrs_state smallint,
  p_fsrs_step integer,
  p_fsrs_retrievability numeric,
  p_elapsed_days integer,
  p_scheduled_days integer,
  p_new_stability numeric,
  p_new_difficulty numeric,
  p_parameter_version integer,
  p_algorithm_state jsonb,
  p_device_id text,
  p_session_id uuid,
  p_client_review_id uuid,
  p_expected_usn bigint default null
)
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_prev public.card_learning_state%rowtype;
  v_user_id uuid := auth.uid();
  v_review_id uuid;
  v_existing_review_id uuid;
  v_existing_card_id uuid;
begin
  if v_user_id is null then
    raise exception 'Authentication is required';
  end if;

  if p_client_review_id is not null then
    select id, card_id into v_existing_review_id, v_existing_card_id
    from public.review_logs
    where user_id = v_user_id
      and client_review_id = p_client_review_id;

    if v_existing_review_id is not null then
      if v_existing_card_id <> p_card_id then
        raise exception 'client_review_id is already associated with another card';
      end if;
      return v_existing_review_id;
    end if;
  end if;

  if p_time_spent_ms is not null and p_time_spent_ms < 0 then
    raise exception 'p_time_spent_ms cannot be negative';
  end if;
  if p_new_interval_days is null or p_new_interval_days < 0 then
    raise exception 'p_new_interval_days must be non-negative';
  end if;
  if p_new_due_at is null then
    raise exception 'p_new_due_at is required';
  end if;
  if p_fsrs_state is null or p_fsrs_state not between 0 and 3 then
    raise exception 'p_fsrs_state must be between 0 and 3';
  end if;
  if p_fsrs_step is not null and p_fsrs_step < 0 then
    raise exception 'p_fsrs_step cannot be negative';
  end if;
  if p_fsrs_retrievability is not null
     and (p_fsrs_retrievability < 0 or p_fsrs_retrievability > 1) then
    raise exception 'p_fsrs_retrievability must be between 0 and 1';
  end if;
  if p_new_stability is not null and p_new_stability <= 0 then
    raise exception 'p_new_stability must be positive';
  end if;
  if p_new_difficulty is not null
     and (p_new_difficulty < 1 or p_new_difficulty > 10) then
    raise exception 'p_new_difficulty must be between 1 and 10';
  end if;

  select * into v_prev
  from public.card_learning_state
  where user_id = v_user_id and card_id = p_card_id
  for update;

  if not found then
    raise exception 'No learning state for card % / current user', p_card_id;
  end if;

  if p_expected_usn is not null and v_prev.usn <> p_expected_usn then
    raise exception 'CARD_STATE_CHANGED';
  end if;

  -- The row lock closes the race between the initial duplicate lookup and a
  -- concurrent review of the same card. The unique index handles the final
  -- race between two requests with the same client_review_id.
  if p_client_review_id is not null then
    select id, card_id into v_existing_review_id, v_existing_card_id
    from public.review_logs
    where user_id = v_user_id
      and client_review_id = p_client_review_id;

    if v_existing_review_id is not null then
      if v_existing_card_id <> p_card_id then
        raise exception 'client_review_id is already associated with another card';
      end if;
      return v_existing_review_id;
    end if;
  end if;

  insert into public.review_logs (
    user_id, card_id, rating, time_spent_ms,
    prev_state, new_state, prev_interval_days, new_interval_days,
    prev_due_at, new_due_at, prev_ease_factor, new_ease_factor,
    prev_stability, new_stability, prev_difficulty, new_difficulty,
    algorithm, device_id, session_id, fsrs_version, elapsed_days,
    scheduled_days, fsrs_retrievability, fsrs_parameter_version,
    client_review_id
  ) values (
    v_user_id, p_card_id, p_rating, p_time_spent_ms,
    v_prev.state, p_new_state, v_prev.interval_days, p_new_interval_days,
    v_prev.due_at, p_new_due_at, v_prev.ease_factor, v_prev.ease_factor,
    v_prev.stability, p_new_stability, v_prev.difficulty, p_new_difficulty,
    'fsrs', p_device_id, p_session_id, 'fsrs-6', p_elapsed_days,
    p_scheduled_days, p_fsrs_retrievability, coalesce(p_parameter_version, 1),
    p_client_review_id
  )
  on conflict (user_id, client_review_id)
  where client_review_id is not null
  do nothing
  returning id into v_review_id;

  if v_review_id is null then
    select id, card_id into v_review_id, v_existing_card_id
    from public.review_logs
    where user_id = v_user_id
      and client_review_id = p_client_review_id;
    if v_existing_card_id <> p_card_id then
      raise exception 'client_review_id is already associated with another card';
    end if;
    return v_review_id;
  end if;

  update public.card_learning_state set
    state = p_new_state,
    due_at = p_new_due_at,
    interval_days = p_new_interval_days,
    stability = p_new_stability,
    difficulty = p_new_difficulty,
    fsrs_version = 'fsrs-6',
    fsrs_state = p_fsrs_state,
    fsrs_step = p_fsrs_step,
    fsrs_retrievability = p_fsrs_retrievability,
    fsrs_last_scheduled_at = now(),
    algorithm = 'fsrs',
    algorithm_state = coalesce(p_algorithm_state, '{}'::jsonb),
    reps = reps + 1,
    lapses = lapses + case when p_rating = 'again' then 1 else 0 end,
    last_reviewed_at = now()
  where user_id = v_user_id and card_id = p_card_id;

  insert into public.daily_statistics (
    user_id, stat_date, cards_studied, new_cards_studied,
    reviews_count, correct_count, incorrect_count, time_studied_ms
  ) values (
    v_user_id, current_date, 1,
    case when v_prev.state = 'new' then 1 else 0 end,
    1,
    case when p_rating in ('good', 'easy') then 1 else 0 end,
    case when p_rating in ('again', 'hard') then 1 else 0 end,
    coalesce(p_time_spent_ms, 0)
  )
  on conflict (user_id, stat_date) do update set
    cards_studied = public.daily_statistics.cards_studied + 1,
    new_cards_studied = public.daily_statistics.new_cards_studied +
      case when v_prev.state = 'new' then 1 else 0 end,
    reviews_count = public.daily_statistics.reviews_count + 1,
    correct_count = public.daily_statistics.correct_count +
      case when p_rating in ('good', 'easy') then 1 else 0 end,
    incorrect_count = public.daily_statistics.incorrect_count +
      case when p_rating in ('again', 'hard') then 1 else 0 end,
    time_studied_ms = public.daily_statistics.time_studied_ms + coalesce(p_time_spent_ms, 0),
    updated_at = now();

  return v_review_id;
end;
$$;

-- Preserve the 0014 API while routing it through the hardened transaction.
create or replace function public.record_review_fsrs6(
  p_card_id uuid,
  p_rating public.review_rating,
  p_time_spent_ms integer,
  p_new_state public.card_state,
  p_new_interval_days numeric,
  p_new_due_at timestamptz,
  p_fsrs_state smallint,
  p_fsrs_step integer,
  p_fsrs_retrievability numeric,
  p_elapsed_days integer,
  p_scheduled_days integer,
  p_new_stability numeric,
  p_new_difficulty numeric,
  p_parameter_version integer default 1,
  p_algorithm_state jsonb default '{}'::jsonb,
  p_device_id text default null,
  p_session_id uuid default null
)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  perform public.record_review_fsrs6_idempotent(
    p_card_id,
    p_rating,
    p_time_spent_ms,
    p_new_state,
    p_new_interval_days,
    p_new_due_at,
    p_fsrs_state,
    p_fsrs_step,
    p_fsrs_retrievability,
    p_elapsed_days,
    p_scheduled_days,
    p_new_stability,
    p_new_difficulty,
    p_parameter_version,
    p_algorithm_state,
    p_device_id,
    p_session_id,
    null,
    null
  );
end;
$$;

comment on function public.record_review_fsrs6_idempotent(
  uuid, public.review_rating, integer, public.card_state, numeric,
  timestamptz, smallint, integer, numeric, integer, integer, numeric,
  numeric, integer, jsonb, text, uuid, uuid, bigint
) is
  'Atomic FSRS-6 review persistence with a per-user client idempotency key.';

-- ---------------------------------------------------------------------------
-- Safer sync query and maintenance helper.
-- The incremental cursor is global, but active content is restricted to rows
-- owned by the authenticated user. Shared/public content can be fetched by its
-- normal read policies and is not mixed into a private offline cursor.
-- ---------------------------------------------------------------------------
create or replace function public.get_incremental_sync(
  p_after_usn bigint default 0,
  p_limit integer default 500
)
returns table (
  entity_type text,
  entity_key text,
  usn bigint,
  is_deleted boolean,
  payload jsonb
)
language sql
security invoker
stable
set search_path = public
as $$
  with changes as (
    select 'deck'::text, d.id::text, d.usn, false, to_jsonb(d)
    from public.decks d
    where d.user_id = auth.uid() and d.deleted_at is null and d.usn > p_after_usn

    union all
    select 'note', n.id::text, n.usn, false, to_jsonb(n)
    from public.notes n
    where n.user_id = auth.uid() and n.deleted_at is null and n.usn > p_after_usn

    union all
    select 'card', c.id::text, c.usn, false, to_jsonb(c)
    from public.cards c
    where c.user_id = auth.uid() and c.deleted_at is null and c.usn > p_after_usn

    union all
    select 'card_media', m.id::text, m.usn, false, to_jsonb(m)
    from public.card_media m
    where m.user_id = auth.uid() and m.usn > p_after_usn

    union all
    select 'card_learning_state', s.id::text, s.usn, false, to_jsonb(s)
    from public.card_learning_state s
    where s.user_id = auth.uid() and s.usn > p_after_usn

    union all
    select 'review_log', r.id::text, r.usn, false, to_jsonb(r)
    from public.review_logs r
    where r.user_id = auth.uid() and r.usn > p_after_usn

    union all
    select 'tag', t.id::text, t.usn, false, to_jsonb(t)
    from public.tags t
    where t.user_id = auth.uid() and t.usn > p_after_usn

    union all
    select 'card_template', t.id::text, t.usn, false, to_jsonb(t)
    from public.card_templates t
    where t.user_id = auth.uid() and t.usn > p_after_usn

    union all
    select 'study_settings', s.user_id::text, s.usn, false, to_jsonb(s)
    from public.study_settings s
    where s.user_id = auth.uid() and s.usn > p_after_usn

    union all
    select 'user_deck_settings', s.user_id::text || ':' || s.deck_id::text,
           s.usn, false, to_jsonb(s)
    from public.user_deck_settings s
    where s.user_id = auth.uid() and s.usn > p_after_usn

    union all
    select 'daily_statistics', s.user_id::text || ':' || s.stat_date::text,
           s.usn, false, to_jsonb(s)
    from public.daily_statistics s
    where s.user_id = auth.uid() and s.usn > p_after_usn

    union all
    select 'note_card_definition', d.id::text, d.usn, false, to_jsonb(d)
    from public.note_card_definitions d
    where d.usn > p_after_usn

    union all
    select 'note_cloze_deletion', d.id::text, d.usn, false, to_jsonb(d)
    from public.note_cloze_deletions d
    where d.usn > p_after_usn

    union all
    select 'fsrs_optimization_run', o.id::text, o.usn, false, to_jsonb(o)
    from public.fsrs_optimization_runs o
    where o.user_id = auth.uid() and o.usn > p_after_usn

    union all
    select 'card_tag', ct.card_id::text || ':' || ct.tag_id::text,
           ct.usn, false, to_jsonb(ct)
    from public.card_tags ct
    join public.cards c on c.id = ct.card_id
    where c.user_id = auth.uid() and ct.usn > p_after_usn

    union all
    select g.entity_type, g.entity_key, g.usn, true,
           jsonb_build_object(
             'entity_type', g.entity_type,
             'entity_key', g.entity_key,
             'deleted_at', g.deleted_at
           )
    from public.graves g
    where g.user_id = auth.uid() and g.usn > p_after_usn
  )
  select *
  from changes
  order by usn asc
  limit least(greatest(coalesce(p_limit, 500), 1), 5000);
$$;

create or replace function public.list_orphaned_card_media(
  p_limit integer default 100
)
returns table (
  media_id uuid,
  storage_bucket text,
  storage_path text
)
language sql
security invoker
stable
set search_path = public
as $$
  select m.id, m.storage_bucket, m.storage_path
  from public.card_media m
  where m.user_id = auth.uid()
    and not exists (
      select 1
      from public.cards c
      where c.id = m.card_id and c.deleted_at is null
    )
  order by m.created_at asc
  limit least(greatest(coalesce(p_limit, 100), 1), 1000);
$$;

comment on function public.get_incremental_sync(bigint, integer) is
  'Returns owned active rows and owned tombstones after a global USN cursor; call repeatedly until fewer than the requested limit are returned.';
comment on function public.list_orphaned_card_media(integer) is
  'Lists user-owned media references whose card is missing or soft-deleted; deletion from Storage belongs to a trusted cleanup worker.';


-- ================= SOURCE 0016_security_advisors_hardening.sql =================
-- Flashi 0016: harden public views and internal trigger functions after
-- Supabase security advisor inspection.

-- Make the deck tree obey the querying user's permissions and RLS policies.
alter view public.v_deck_tree set (security_invoker = true);

-- Pin search_path on existing functions that predate the worker hardening.
alter function public.set_updated_at() set search_path = public;
alter function public.prevent_review_log_mutation() set search_path = public;
alter function public.get_due_cards(uuid, integer) set search_path = public;
alter function public.record_review(
  uuid, public.review_rating, integer, public.card_state, numeric,
  timestamptz, numeric, numeric, numeric, public.srs_algorithm, text, uuid
) set search_path = public;
alter function public.get_current_streak() set search_path = public;
alter function public.soft_delete_deck(uuid) set search_path = public;
alter function public.get_fsrs_optimization_status() set search_path = public;
alter function public.enqueue_fsrs_optimization() set search_path = public;

-- These functions are invoked by database triggers, not by the public RPC API.
-- Keep SECURITY DEFINER where required for trigger writes, but remove direct
-- execution from API roles.
revoke execute on function public.assign_sync_usn() from public, anon, authenticated;
revoke execute on function public.record_sync_grave() from public, anon, authenticated;
revoke execute on function public.handle_new_user() from public, anon, authenticated;

-- Some projects may already have this helper from an external migration. If it
-- exists, it is internal and should not be callable through PostgREST.
do $$
begin
  if to_regprocedure('public.rls_auto_enable()') is not null then
    revoke execute on function public.rls_auto_enable() from public, anon, authenticated;
  end if;
end;
$$;


-- ================= SOURCE 0017_fix_rls_recursion_and_fk_indexes.sql =================
-- Flashi 0017: remove recursive RLS evaluation from shared-deck policies
-- and add the remaining foreign-key indexes reported by the performance advisor.

create schema if not exists private;

-- These helpers run with the migration owner so policy evaluation can inspect
-- the relationship tables without recursively evaluating their own policies.
-- They only answer membership/ownership for the current JWT subject.
create or replace function private.is_deck_owner(p_deck_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.decks d
    where d.id = p_deck_id
      and d.user_id = (select auth.uid())
  );
$$;

create or replace function private.is_deck_collaborator(p_deck_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.deck_collaborators dc
    where dc.deck_id = p_deck_id
      and dc.user_id = (select auth.uid())
  );
$$;

grant usage on schema private to public;
grant execute on function private.is_deck_owner(uuid) to public;
grant execute on function private.is_deck_collaborator(uuid) to public;

-- Replace the mutually recursive policies with calls to the isolated helpers.
drop policy if exists deck_collaborators_owner_manage on public.deck_collaborators;
create policy deck_collaborators_owner_manage on public.deck_collaborators
  for all using (private.is_deck_owner(deck_collaborators.deck_id))
  with check (private.is_deck_owner(deck_collaborators.deck_id));

drop policy if exists decks_shared_read on public.decks;
create policy decks_shared_read on public.decks
  for select using (private.is_deck_collaborator(decks.id));

drop policy if exists cards_shared_read on public.cards;
create policy cards_shared_read on public.cards
  for select using (private.is_deck_collaborator(cards.deck_id));

-- Cover the FK columns highlighted by the performance advisor.
create index if not exists idx_anki_transfer_jobs_source_deck
  on public.anki_transfer_jobs (source_deck_id);
create index if not exists idx_anki_transfer_jobs_target_deck
  on public.anki_transfer_jobs (target_deck_id);
create index if not exists idx_card_learning_state_card
  on public.card_learning_state (card_id);
create index if not exists idx_cards_template
  on public.cards (template_id)
  where template_id is not null;
create index if not exists idx_notes_template
  on public.notes (template_id)
  where template_id is not null;
create index if not exists idx_user_deck_settings_deck
  on public.user_deck_settings (deck_id);


-- ================= SOURCE 0022_harden_image_occlusion_grant.sql =================
-- Flashi 0022: restrict image-occlusion materialization to authenticated users.
-- The RPC validates auth.uid() and ownership internally, but it should not
-- retain the default PUBLIC EXECUTE privilege of a SECURITY DEFINER function.

revoke execute on function public.create_image_occlusion_note(uuid, jsonb) from public, anon;
grant execute on function public.create_image_occlusion_note(uuid, jsonb) to authenticated;


-- ================= SOURCE 0023_security_definer_cleanup.sql =================
-- Flashi 0023: remove avoidable SECURITY DEFINER/search_path warnings.
-- Image occlusion already performs owner validation and all writes are covered
-- by authenticated-user RLS, so it does not need definer privileges.

alter function public.get_incremental_sync(bigint, integer)
  set search_path = public;

alter function public.create_image_occlusion_note(uuid, jsonb)
  security invoker;

