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
