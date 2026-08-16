-- 0006_learning_reviews.sql
-- card_learning_state: current SRS state, one row per (user, card).
-- review_logs: full append-only review history, never updated/deleted.
--
-- Algorithm math (SM-2/FSRS calculations) is deliberately NOT done in
-- the database. The app/edge-function layer computes the next state
-- and passes the results to record_review() (0010), which only
-- persists them atomically. This keeps business logic out of the DB,
-- per the brief's own constraint, while still guaranteeing
-- consistency between review_logs, card_learning_state and
-- daily_statistics via a single transactional function.

create table if not exists public.card_learning_state (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  card_id uuid not null references public.cards(id) on delete cascade,
  state public.card_state not null default 'new',
  is_suspended boolean not null default false,
  due_at timestamptz not null default now(),
  interval_days numeric(10,4) not null default 0,
  ease_factor numeric(5,2),      -- SM-2 specific, nullable
  stability numeric(10,4),       -- FSRS specific, nullable
  difficulty numeric(10,4),      -- FSRS specific, nullable
  reps integer not null default 0,
  lapses integer not null default 0,
  last_reviewed_at timestamptz,
  algorithm public.srs_algorithm not null default 'fsrs',
  algorithm_state jsonb not null default '{}'::jsonb, -- catch-all for future algorithms
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, card_id)
);

-- The single most important index in the schema: serves
-- "which cards does this user need to study now".
create index if not exists idx_learning_due
  on public.card_learning_state (user_id, due_at)
  where is_suspended = false;

create index if not exists idx_learning_state_lookup
  on public.card_learning_state (user_id, state);

create table if not exists public.review_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  card_id uuid not null references public.cards(id) on delete cascade,
  reviewed_at timestamptz not null default now(),
  rating public.review_rating not null,
  time_spent_ms integer,
  prev_state public.card_state,
  new_state public.card_state not null,
  prev_interval_days numeric(10,4),
  new_interval_days numeric(10,4),
  prev_due_at timestamptz,
  new_due_at timestamptz not null,
  prev_ease_factor numeric(5,2),
  new_ease_factor numeric(5,2),
  prev_stability numeric(10,4),
  new_stability numeric(10,4),
  prev_difficulty numeric(10,4),
  new_difficulty numeric(10,4),
  algorithm public.srs_algorithm not null,
  device_id text,     -- for multi-device sync / conflict tracing
  session_id uuid,    -- groups reviews within one study session
  created_at timestamptz not null default now()
);

create index if not exists idx_review_logs_user_date on public.review_logs (user_id, reviewed_at desc);
create index if not exists idx_review_logs_card on public.review_logs (card_id);
create index if not exists idx_review_logs_session on public.review_logs (session_id);

comment on table public.review_logs is
  'Append-only. INSERT/SELECT only -- enforced by both RLS (0009) and a trigger (0008). At high volume (10M+ rows), consider monthly range partitioning by reviewed_at; not implemented now to avoid premature complexity.';
