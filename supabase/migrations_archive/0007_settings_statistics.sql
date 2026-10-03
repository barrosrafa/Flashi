-- 0007_settings_statistics.sql

create table if not exists public.study_settings (
  user_id uuid primary key references auth.users(id) on delete cascade,
  algorithm public.srs_algorithm not null default 'fsrs',
  new_cards_per_day integer not null default 20 check (new_cards_per_day >= 0),
  max_reviews_per_day integer not null default 200 check (max_reviews_per_day >= 0),
  learning_steps_minutes integer[] not null default '{1,10}',
  relearning_steps_minutes integer[] not null default '{10}',
  graduating_interval_days integer not null default 1,
  easy_interval_days integer not null default 4,
  starting_ease numeric(5,2) not null default 2.5,
  fsrs_params jsonb not null default '{}'::jsonb, -- e.g. per-user FSRS weight vector
  day_start_hour smallint not null default 4 check (day_start_hour between 0 and 23),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.study_settings is
  'Row created automatically by handle_new_user() trigger (0008) for every new auth.users row.';

create table if not exists public.user_deck_settings (
  user_id uuid not null references auth.users(id) on delete cascade,
  deck_id uuid not null references public.decks(id) on delete cascade,
  overrides jsonb not null default '{}'::jsonb, -- overrides any key from study_settings for this deck
  is_favorite boolean not null default false,
  display_order integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, deck_id)
);

-- Aggregated daily rollup, written incrementally by record_review() (0010).
-- streak is intentionally NOT stored here (see get_current_streak() in 0010)
-- to avoid the value drifting out of sync with the underlying rows.
create table if not exists public.daily_statistics (
  user_id uuid not null references auth.users(id) on delete cascade,
  stat_date date not null,
  cards_studied integer not null default 0,
  new_cards_studied integer not null default 0,
  reviews_count integer not null default 0,
  correct_count integer not null default 0,
  incorrect_count integer not null default 0,
  time_studied_ms bigint not null default 0,
  updated_at timestamptz not null default now(),
  primary key (user_id, stat_date)
);

create index if not exists idx_daily_stats_user_date on public.daily_statistics (user_id, stat_date desc);
