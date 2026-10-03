-- Flashi schema snapshot: 03_study_state_and_gamification.sql
-- Study state, synchronization entities, AI ingestion and gamification tables/contracts.
-- Generated from the v1 baseline; historical sources remain in ../migrations_archive/.
-- Apply strictly in lexical order.


-- ================= SOURCE 0006_learning_reviews.sql =================
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


-- ================= SOURCE 0007_settings_statistics.sql =================
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


-- ================= SOURCE 0013_incremental_sync_usn_graves.sql =================
-- Flashi 0013: server-assigned USN and tombstones (graves) for
-- deterministic incremental multi-device synchronization.

create sequence if not exists public.sync_usn_seq
  as bigint
  minvalue 1
  start with 1
  increment by 1
  no cycle;

-- Every synchronizable row receives a monotonically increasing server USN.
-- A single sequence is intentional: clients can maintain one cursor across
-- entities and cannot miss a write caused by another table's trigger.
alter table public.decks add column if not exists usn bigint not null default nextval('public.sync_usn_seq');
alter table public.cards add column if not exists usn bigint not null default nextval('public.sync_usn_seq');
alter table public.notes add column if not exists usn bigint not null default nextval('public.sync_usn_seq');
alter table public.card_templates add column if not exists usn bigint not null default nextval('public.sync_usn_seq');
alter table public.tags add column if not exists usn bigint not null default nextval('public.sync_usn_seq');
alter table public.card_media add column if not exists usn bigint not null default nextval('public.sync_usn_seq');
alter table public.card_learning_state add column if not exists usn bigint not null default nextval('public.sync_usn_seq');
alter table public.review_logs add column if not exists usn bigint not null default nextval('public.sync_usn_seq');
alter table public.study_settings add column if not exists usn bigint not null default nextval('public.sync_usn_seq');
alter table public.user_deck_settings add column if not exists usn bigint not null default nextval('public.sync_usn_seq');
alter table public.daily_statistics add column if not exists usn bigint not null default nextval('public.sync_usn_seq');
alter table public.note_card_definitions add column if not exists usn bigint not null default nextval('public.sync_usn_seq');
alter table public.note_cloze_deletions add column if not exists usn bigint not null default nextval('public.sync_usn_seq');
alter table public.fsrs_optimization_runs add column if not exists usn bigint not null default nextval('public.sync_usn_seq');
alter table public.card_tags add column if not exists usn bigint not null default nextval('public.sync_usn_seq');

alter table public.decks alter column usn set default nextval('public.sync_usn_seq');
alter table public.cards alter column usn set default nextval('public.sync_usn_seq');
alter table public.notes alter column usn set default nextval('public.sync_usn_seq');
alter table public.card_templates alter column usn set default nextval('public.sync_usn_seq');
alter table public.tags alter column usn set default nextval('public.sync_usn_seq');
alter table public.card_media alter column usn set default nextval('public.sync_usn_seq');
alter table public.card_learning_state alter column usn set default nextval('public.sync_usn_seq');
alter table public.review_logs alter column usn set default nextval('public.sync_usn_seq');
alter table public.study_settings alter column usn set default nextval('public.sync_usn_seq');
alter table public.user_deck_settings alter column usn set default nextval('public.sync_usn_seq');
alter table public.daily_statistics alter column usn set default nextval('public.sync_usn_seq');
alter table public.note_card_definitions alter column usn set default nextval('public.sync_usn_seq');
alter table public.note_cloze_deletions alter column usn set default nextval('public.sync_usn_seq');
alter table public.fsrs_optimization_runs alter column usn set default nextval('public.sync_usn_seq');
alter table public.card_tags alter column usn set default nextval('public.sync_usn_seq');

create table if not exists public.graves (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  entity_type text not null check (entity_type in (
    'deck', 'card', 'note', 'card_template', 'tag', 'card_media',
    'card_learning_state', 'review_log', 'study_settings',
    'user_deck_settings', 'daily_statistics', 'note_card_definition',
    'note_cloze_deletion', 'fsrs_optimization_run', 'card_tag'
  )),
  entity_key text not null,
  usn bigint not null,
  deleted_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (user_id, entity_type, entity_key)
);

create index if not exists idx_graves_user_usn
  on public.graves (user_id, usn);
create index if not exists idx_graves_entity
  on public.graves (user_id, entity_type, entity_key);

-- Generic trigger: a new row and every update receive a server USN. The
-- function is deliberately SECURITY DEFINER so clients cannot forge cursors.
create or replace function public.assign_sync_usn()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.usn := nextval('public.sync_usn_seq');
  return new;
end;
$$;

-- Generic grave trigger works with UUID primary keys and the card_tags
-- composite key. It records both soft deletes and administrative hard deletes.
create or replace function public.record_sync_grave()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row jsonb;
  v_old jsonb;
  v_user_id uuid;
  v_entity_key text;
  v_usn bigint;
  v_deleted_at timestamptz;
  v_should_record boolean := false;
begin
  v_row := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  v_old := case when tg_op = 'UPDATE' then to_jsonb(old) else '{}'::jsonb end;

  v_deleted_at := nullif(v_row ->> 'deleted_at', '')::timestamptz;
  v_should_record := tg_op = 'DELETE'
    or (tg_op = 'UPDATE'
      and v_deleted_at is not null
      and nullif(v_old ->> 'deleted_at', '') is null);

  if not v_should_record then
    if tg_op = 'DELETE' then
      return old;
    end if;
    return new;
  end if;

  v_user_id := nullif(v_row ->> 'user_id', '')::uuid;
  if v_user_id is null and tg_argv[0] = 'card_tag' then
    select c.user_id into v_user_id
    from public.cards c
    where c.id = (v_row ->> 'card_id')::uuid;
  end if;

  v_entity_key := case tg_argv[0]
    when 'user_deck_settings' then concat(v_row ->> 'user_id', ':', v_row ->> 'deck_id')
    when 'daily_statistics' then concat(v_row ->> 'user_id', ':', v_row ->> 'stat_date')
    when 'card_tag' then concat(v_row ->> 'card_id', ':', v_row ->> 'tag_id')
    else nullif(v_row ->> 'id', '')
  end;
  v_usn := nullif(v_row ->> 'usn', '')::bigint;

  if v_user_id is not null and v_entity_key is not null and v_usn is not null then
    insert into public.graves (user_id, entity_type, entity_key, usn, deleted_at)
    values (v_user_id, tg_argv[0], v_entity_key, v_usn, coalesce(v_deleted_at, now()))
    on conflict (user_id, entity_type, entity_key) do update set
      usn = excluded.usn,
      deleted_at = excluded.deleted_at;
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

-- Attach USN and grave triggers to all synchronizable entities. Trigger names
-- are stable, so rerunning this migration is safe.
do $$
declare
  v_pair text;
  v_table text;
  v_entity text;
begin
  foreach v_pair in array array[
    'decks:deck',
    'cards:card',
    'notes:note',
    'card_templates:card_template',
    'tags:tag',
    'card_media:card_media',
    'card_learning_state:card_learning_state',
    'review_logs:review_log',
    'study_settings:study_settings',
    'user_deck_settings:user_deck_settings',
    'daily_statistics:daily_statistics',
    'note_card_definitions:note_card_definition',
    'note_cloze_deletions:note_cloze_deletion',
    'fsrs_optimization_runs:fsrs_optimization_run',
    'card_tags:card_tag'
  ]::text[]
  loop
    v_table := split_part(v_pair, ':', 1);
    v_entity := split_part(v_pair, ':', 2);

    execute format('drop trigger if exists %I on public.%I', 'trg_' || v_table || '_sync_usn', v_table);
    execute format(
      'create trigger %I before insert or update on public.%I for each row execute function public.assign_sync_usn()',
      'trg_' || v_table || '_sync_usn', v_table
    );

    execute format('drop trigger if exists %I on public.%I', 'trg_' || v_table || '_sync_grave', v_table);
    execute format(
      'create trigger %I after update or delete on public.%I for each row execute function public.record_sync_grave(%L)',
      'trg_' || v_table || '_sync_grave', v_table, v_entity
    );
  end loop;
end $$;

-- Backfill graves for rows soft-deleted before this migration existed.
insert into public.graves (user_id, entity_type, entity_key, usn, deleted_at)
select user_id, 'deck', id::text, usn, deleted_at from public.decks
where deleted_at is not null
on conflict (user_id, entity_type, entity_key) do update set usn = excluded.usn, deleted_at = excluded.deleted_at;

insert into public.graves (user_id, entity_type, entity_key, usn, deleted_at)
select user_id, 'note', id::text, usn, deleted_at from public.notes
where deleted_at is not null
on conflict (user_id, entity_type, entity_key) do update set usn = excluded.usn, deleted_at = excluded.deleted_at;

insert into public.graves (user_id, entity_type, entity_key, usn, deleted_at)
select user_id, 'card', id::text, usn, deleted_at from public.cards
where deleted_at is not null
on conflict (user_id, entity_type, entity_key) do update set usn = excluded.usn, deleted_at = excluded.deleted_at;

alter table public.graves enable row level security;
drop policy if exists graves_owner_read on public.graves;
create policy graves_owner_read on public.graves
  for select using (auth.uid() = user_id);

-- Index every principal queue/sync access path. Partial indexes keep deleted
-- historical rows out of the hot path.
create index if not exists idx_decks_user_usn on public.decks (user_id, usn) where deleted_at is null;
create index if not exists idx_cards_user_usn on public.cards (user_id, usn) where deleted_at is null;
create index if not exists idx_notes_user_usn on public.notes (user_id, usn) where deleted_at is null;
create index if not exists idx_card_media_user_usn on public.card_media (user_id, usn);
create index if not exists idx_learning_state_user_usn on public.card_learning_state (user_id, usn);
create index if not exists idx_review_logs_user_usn on public.review_logs (user_id, usn);
create index if not exists idx_study_settings_user_usn on public.study_settings (user_id, usn);
create index if not exists idx_daily_statistics_user_usn on public.daily_statistics (user_id, usn);

-- Returns active rows plus tombstones after one global cursor. Payloads are
-- deliberately JSONB so mobile/web clients can apply an entity without a
-- second round trip per table. RLS remains active because this is invoker.
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
as $$
  with changes as (
    select 'deck'::text as entity_type, d.id::text as entity_key, d.usn, false as is_deleted, to_jsonb(d) as payload
    from public.decks d where d.deleted_at is null and d.usn > p_after_usn
    union all
    select 'note', n.id::text, n.usn, false, to_jsonb(n)
    from public.notes n where n.deleted_at is null and n.usn > p_after_usn
    union all
    select 'card', c.id::text, c.usn, false, to_jsonb(c)
    from public.cards c where c.deleted_at is null and c.usn > p_after_usn
    union all
    select 'card_media', m.id::text, m.usn, false, to_jsonb(m)
    from public.card_media m where m.usn > p_after_usn
    union all
    select 'card_learning_state', s.id::text, s.usn, false, to_jsonb(s)
    from public.card_learning_state s where s.usn > p_after_usn
    union all
    select 'review_log', r.id::text, r.usn, false, to_jsonb(r)
    from public.review_logs r where r.usn > p_after_usn
    union all
    select 'tag', t.id::text, t.usn, false, to_jsonb(t)
    from public.tags t where t.usn > p_after_usn
    union all
    select 'card_template', t.id::text, t.usn, false, to_jsonb(t)
    from public.card_templates t where t.user_id = auth.uid() and t.usn > p_after_usn
    union all
    select 'study_settings', s.user_id::text, s.usn, false, to_jsonb(s)
    from public.study_settings s where s.user_id = auth.uid() and s.usn > p_after_usn
    union all
    select 'user_deck_settings', s.user_id::text || ':' || s.deck_id::text, s.usn, false, to_jsonb(s)
    from public.user_deck_settings s where s.user_id = auth.uid() and s.usn > p_after_usn
    union all
    select 'daily_statistics', s.user_id::text || ':' || s.stat_date::text, s.usn, false, to_jsonb(s)
    from public.daily_statistics s where s.user_id = auth.uid() and s.usn > p_after_usn
    union all
    select 'note_card_definition', d.id::text, d.usn, false, to_jsonb(d)
    from public.note_card_definitions d where d.usn > p_after_usn
    union all
    select 'note_cloze_deletion', d.id::text, d.usn, false, to_jsonb(d)
    from public.note_cloze_deletions d where d.usn > p_after_usn
    union all
    select 'fsrs_optimization_run', o.id::text, o.usn, false, to_jsonb(o)
    from public.fsrs_optimization_runs o where o.user_id = auth.uid() and o.usn > p_after_usn
    union all
    select g.entity_type, g.entity_key, g.usn, true,
           jsonb_build_object('entity_type', g.entity_type, 'entity_key', g.entity_key, 'deleted_at', g.deleted_at)
    from public.graves g where g.usn > p_after_usn
  )
  select * from changes
  order by usn asc
  limit least(greatest(p_limit, 1), 5000);
$$;

comment on table public.graves is
  'Tombstones for incremental sync. A client must retain its last server USN and apply graves before advancing the cursor.';
comment on function public.get_incremental_sync(bigint, integer) is
  'Returns active rows and graves after a global server-assigned USN cursor; call repeatedly until fewer than the requested limit are returned.';


-- ================= SOURCE 0014_interoperability_mcp.sql =================
-- Flashi 0014: Anki .apkg staging/export contracts, MCP-safe RPCs and
-- complete FSRS-6 review persistence.
--
-- ZIP/SQLite parsing and the MCP transport belong in an Edge Function or
-- application service. This migration provides the durable, auditable,
-- RLS-protected database contracts those services call.

alter table public.notes add column if not exists source_format text not null default 'native';
alter table public.notes add column if not exists external_id text;
alter table public.notes add column if not exists content_hash text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'notes_source_format_check'
      and conrelid = 'public.notes'::regclass
  ) then
    alter table public.notes add constraint notes_source_format_check
      check (source_format in ('native', 'anki_apkg', 'mcp', 'api'));
  end if;
end $$;

create unique index if not exists notes_unique_external_source
  on public.notes (user_id, source_format, external_id)
  where external_id is not null and deleted_at is null;
create index if not exists idx_notes_content_hash
  on public.notes (user_id, content_hash)
  where content_hash is not null and deleted_at is null;

-- Import/export jobs are metadata only. The binary .apkg remains in the
-- private card-media bucket or a dedicated private import bucket, never in a
-- SQL BLOB column.
create table if not exists public.anki_transfer_jobs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  direction text not null,
  status text not null default 'queued',
  storage_path text,
  file_sha256 text,
  source_deck_id uuid references public.decks(id) on delete set null,
  target_deck_id uuid references public.decks(id) on delete set null,
  options jsonb not null default '{}'::jsonb,
  total_notes integer not null default 0,
  imported_notes integer not null default 0,
  imported_cards integer not null default 0,
  skipped_notes integer not null default 0,
  error_message text,
  requested_at timestamptz not null default now(),
  started_at timestamptz,
  completed_at timestamptz,
  usn bigint not null default nextval('public.sync_usn_seq'),
  constraint anki_transfer_direction_check check (direction in ('import', 'export')),
  constraint anki_transfer_status_check check (
    status in ('queued', 'running', 'completed', 'failed', 'cancelled')
  )
);

create index if not exists idx_anki_transfer_user_status
  on public.anki_transfer_jobs (user_id, status, requested_at desc);
create unique index if not exists anki_transfer_idempotency
  on public.anki_transfer_jobs (user_id, direction, file_sha256)
  where file_sha256 is not null;

create table if not exists public.mcp_tool_audit (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  tool_name text not null,
  request_id text,
  input_hash text,
  result_count integer,
  created_at timestamptz not null default now(),
  usn bigint not null default nextval('public.sync_usn_seq')
);

create index if not exists idx_mcp_tool_audit_user_date
  on public.mcp_tool_audit (user_id, created_at desc);

alter table public.anki_transfer_jobs enable row level security;
alter table public.mcp_tool_audit enable row level security;

drop policy if exists anki_transfer_jobs_owner on public.anki_transfer_jobs;
create policy anki_transfer_jobs_owner on public.anki_transfer_jobs
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists mcp_tool_audit_owner_read on public.mcp_tool_audit;
create policy mcp_tool_audit_owner_read on public.mcp_tool_audit
  for select using (auth.uid() = user_id);

drop policy if exists mcp_tool_audit_owner_insert on public.mcp_tool_audit;
create policy mcp_tool_audit_owner_insert on public.mcp_tool_audit
  for insert with check (auth.uid() = user_id);

drop trigger if exists trg_anki_transfer_jobs_sync_usn on public.anki_transfer_jobs;
create trigger trg_anki_transfer_jobs_sync_usn
  before insert or update on public.anki_transfer_jobs
  for each row execute function public.assign_sync_usn();

drop trigger if exists trg_mcp_tool_audit_sync_usn on public.mcp_tool_audit;
create trigger trg_mcp_tool_audit_sync_usn
  before insert or update on public.mcp_tool_audit
  for each row execute function public.assign_sync_usn();

-- A single database contract for the MCP create_note tool. It creates the
-- note and the requested review cards in one transaction, validates ownership
-- of the deck/template, and returns the generated IDs.
create or replace function public.mcp_create_note(
  p_deck_id uuid,
  p_fields jsonb,
  p_template_id uuid default null,
  p_card_definitions jsonb default '[]'::jsonb,
  p_source text default 'mcp',
  p_external_id text default null,
  p_content_hash text default null,
  p_request_id text default null
)
returns table (
  note_id uuid,
  card_ids uuid[]
)
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_note_id uuid;
  v_card_ids uuid[];
  v_card_id uuid;
  v_definition jsonb;
  v_template_id uuid;
  v_ordinal integer := 0;
  v_kind text;
  v_cloze_ordinal integer;
  v_front text;
  v_back text;
begin
  if v_user_id is null then
    raise exception 'Authentication is required';
  end if;
  if p_fields is null or p_fields = '{}'::jsonb then
    raise exception 'p_fields cannot be empty';
  end if;
  if p_card_definitions is null then
    p_card_definitions := '[]'::jsonb;
  end if;
  if jsonb_typeof(p_card_definitions) <> 'array' then
    raise exception 'p_card_definitions must be a JSON array';
  end if;
  if jsonb_array_length(p_card_definitions) = 0 then
    p_card_definitions := jsonb_build_array(
      jsonb_build_object(
        'card_kind', 'basic',
        'front', coalesce(p_fields ->> 'Front', ''),
        'back', coalesce(p_fields ->> 'Back', '')
      )
    );
  end if;

  if not exists (
    select 1 from public.decks d
    where d.id = p_deck_id and d.user_id = v_user_id and d.deleted_at is null
  ) then
    raise exception 'The target deck does not belong to the current user';
  end if;

  v_template_id := p_template_id;
  if v_template_id is not null and not exists (
    select 1 from public.card_templates t
    where t.id = v_template_id and (t.user_id = v_user_id or t.is_system = true)
  ) then
    raise exception 'The template is not accessible to the current user';
  end if;

  insert into public.notes (
    user_id, deck_id, template_id, fields, source_format, source,
    external_id, content_hash
  ) values (
    v_user_id, p_deck_id, v_template_id, p_fields,
    case when p_source = 'mcp' then 'mcp' else 'api' end,
    p_source, p_external_id, p_content_hash
  ) returning id into v_note_id;

  -- A caller may pass a list of rendered card definitions. The SQL boundary
  -- stores the rendered fields; a richer renderer stays in the MCP service.
  for v_definition in select value from jsonb_array_elements(p_card_definitions)
  loop
    v_kind := coalesce(v_definition ->> 'card_kind', 'basic');
    v_cloze_ordinal := nullif(v_definition ->> 'cloze_ordinal', '')::integer;
    v_front := coalesce(v_definition ->> 'front', '');
    v_back := coalesce(v_definition ->> 'back', '');

    if v_front = '' and v_back = '' then
      raise exception 'Each card definition must include front or back';
    end if;

    insert into public.cards (
      user_id, deck_id, template_id, note_group_id, note_id,
      card_ordinal, card_kind, cloze_ordinal, fields
    ) values (
      v_user_id, p_deck_id, v_template_id, v_note_id, v_note_id,
      v_ordinal, v_kind, v_cloze_ordinal,
      jsonb_build_object('Front', v_front, 'Back', v_back)
    ) returning id into v_card_id;

    insert into public.card_learning_state (user_id, card_id)
    values (v_user_id, v_card_id)
    on conflict (user_id, card_id) do nothing;

    v_card_ids := array_append(coalesce(v_card_ids, '{}'::uuid[]), v_card_id);
    v_ordinal := v_ordinal + 1;
  end loop;

  insert into public.mcp_tool_audit (
    user_id, tool_name, request_id, result_count
  ) values (
    v_user_id, 'mcp_create_note', p_request_id, v_ordinal
  );

  return query select v_note_id, coalesce(v_card_ids, '{}'::uuid[]);
end;
$$;

-- Read-only MCP search contract. Semantic search is preferred when the
-- caller supplies an embedding; lexical fallback keeps the tool useful while
-- the embedding worker is processing a note.
create or replace function public.mcp_search_notes(
  p_query text,
  p_query_embedding extensions.vector(1536) default null,
  p_limit integer default 20,
  p_request_id text default null
)
returns table (
  note_id uuid,
  deck_id uuid,
  fields jsonb,
  similarity real,
  match_type text
)
language plpgsql
security invoker
set search_path = public, extensions
as $$
declare
  v_count integer := 0;
begin
  if auth.uid() is null then
    raise exception 'Authentication is required';
  end if;

  if p_query_embedding is not null then
    return query
      select s.note_id, s.deck_id, s.fields, s.similarity, 'semantic'::text
      from public.search_notes_by_embedding(p_query_embedding, 0.60, p_limit) s;
    get diagnostics v_count = row_count;
  else
    return query
      select n.id, n.deck_id, n.fields, 1.0::real, 'lexical'::text
      from public.notes n
      where n.user_id = auth.uid()
        and n.deleted_at is null
        and n.search_document @@ websearch_to_tsquery('simple', p_query)
      order by ts_rank(n.search_document, websearch_to_tsquery('simple', p_query)) desc
      limit least(greatest(p_limit, 1), 100);
    get diagnostics v_count = row_count;
  end if;

  insert into public.mcp_tool_audit (
    user_id, tool_name, request_id, result_count
  ) values (
    auth.uid(), 'mcp_search_notes', p_request_id, v_count
  );
end;
$$;

-- Full FSRS-6 persistence endpoint. The scheduler computes these values in
-- the application layer; this RPC guarantees audit/state/statistics atomicity.
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
as $$
declare
  v_prev public.card_learning_state%rowtype;
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'Authentication is required';
  end if;

  select * into v_prev
  from public.card_learning_state
  where user_id = v_user_id and card_id = p_card_id
  for update;

  if not found then
    raise exception 'No learning state for card % / current user', p_card_id;
  end if;

  insert into public.review_logs (
    user_id, card_id, rating, time_spent_ms,
    prev_state, new_state, prev_interval_days, new_interval_days,
    prev_due_at, new_due_at, prev_ease_factor, new_ease_factor,
    prev_stability, new_stability, prev_difficulty, new_difficulty,
    algorithm, device_id, session_id, fsrs_version, elapsed_days,
    scheduled_days, fsrs_retrievability, fsrs_parameter_version
  ) values (
    v_user_id, p_card_id, p_rating, p_time_spent_ms,
    v_prev.state, p_new_state, v_prev.interval_days, p_new_interval_days,
    v_prev.due_at, p_new_due_at, v_prev.ease_factor, v_prev.ease_factor,
    v_prev.stability, p_new_stability, v_prev.difficulty, p_new_difficulty,
    'fsrs', p_device_id, p_session_id, 'fsrs-6', p_elapsed_days,
    p_scheduled_days, p_fsrs_retrievability, p_parameter_version
  );

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
    algorithm_state = p_algorithm_state,
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
end;
$$;

comment on table public.anki_transfer_jobs is
  'Queue and audit metadata for .apkg import/export. Binary packages stay in private object storage; parsers run outside PostgreSQL.';
comment on function public.mcp_create_note(uuid, jsonb, uuid, jsonb, text, text, text, text) is
  'Atomic, RLS-protected database contract for an MCP create-note tool. The MCP transport must delegate the user session.';
comment on function public.mcp_search_notes(text, extensions.vector, integer, text) is
  'RLS-protected semantic/lexical search contract for an MCP read tool.';


-- ================= SOURCE 0021_ai_ingestion_occlusion_references.sql =================
-- Flashi 0021: AI document ingestion jobs, image occlusion and note references.
-- This migration is additive and safe to rerun after 0020.

-- ---------------------------------------------------------------------------
-- Shared enums.
-- ---------------------------------------------------------------------------
do $$
begin
  create type public.generation_source_type as enum ('pdf_document', 'youtube_url', 'raw_text_block', 'web_page');
exception when duplicate_object then null;
end $$;

do $$
begin
  create type public.job_status_type as enum ('queued', 'processing', 'completed', 'failed');
exception when duplicate_object then null;
end $$;

-- ---------------------------------------------------------------------------
-- AI ingestion queue.
-- ---------------------------------------------------------------------------
create table if not exists public.ai_ingestion_jobs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  deck_id uuid not null references public.decks(id) on delete cascade,
  source_type public.generation_source_type not null,
  source_reference text,
  status public.job_status_type not null default 'queued',
  notes_generated_count integer not null default 0 check (notes_generated_count >= 0),
  cards_generated_count integer not null default 0 check (cards_generated_count >= 0),
  error_message text,
  usn bigint not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);
create index if not exists idx_ai_ingestion_jobs_user_status
  on public.ai_ingestion_jobs (user_id, status, created_at desc);
create index if not exists idx_ai_ingestion_jobs_deck
  on public.ai_ingestion_jobs (deck_id, created_at desc);

alter table public.ai_ingestion_jobs enable row level security;
drop policy if exists ai_ingestion_jobs_owner_select on public.ai_ingestion_jobs;
create policy ai_ingestion_jobs_owner_select on public.ai_ingestion_jobs
  for select using (auth.uid() = user_id);
drop policy if exists ai_ingestion_jobs_owner_insert on public.ai_ingestion_jobs;
create policy ai_ingestion_jobs_owner_insert on public.ai_ingestion_jobs
  for insert with check (auth.uid() = user_id);
drop policy if exists ai_ingestion_jobs_owner_update on public.ai_ingestion_jobs;
create policy ai_ingestion_jobs_owner_update on public.ai_ingestion_jobs
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists ai_ingestion_jobs_owner_delete on public.ai_ingestion_jobs;
create policy ai_ingestion_jobs_owner_delete on public.ai_ingestion_jobs
  for delete using (auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- Image occlusion and cross-note references.
-- ---------------------------------------------------------------------------
create table if not exists public.note_image_occlusion_boxes (
  id uuid primary key default gen_random_uuid(),
  note_id uuid not null references public.notes(id) on delete cascade,
  cloze_ordinal integer not null check (cloze_ordinal > 0),
  label_text text,
  x_pos double precision not null,
  y_pos double precision not null,
  width_pct double precision not null,
  height_pct double precision not null,
  metadata jsonb not null default '{}'::jsonb,
  usn bigint not null default 0,
  created_at timestamptz not null default now(),
  constraint note_image_occlusion_box_coordinates_check check (
    x_pos >= 0 and y_pos >= 0 and width_pct > 0 and height_pct > 0
    and x_pos + width_pct <= 100 and y_pos + height_pct <= 100
  ),
  unique (note_id, cloze_ordinal)
);
create index if not exists idx_note_image_occlusion_boxes_note
  on public.note_image_occlusion_boxes (note_id, cloze_ordinal);

create table if not exists public.note_references (
  id uuid primary key default gen_random_uuid(),
  source_note_id uuid not null references public.notes(id) on delete cascade,
  target_note_id uuid not null references public.notes(id) on delete cascade,
  block_id uuid,
  context_snippet text,
  usn bigint not null default 0,
  created_at timestamptz not null default now(),
  constraint note_references_not_self check (source_note_id <> target_note_id)
);
create index if not exists idx_note_references_source_target
  on public.note_references (source_note_id, target_note_id);
create index if not exists idx_note_references_target
  on public.note_references (target_note_id);

alter table public.note_image_occlusion_boxes enable row level security;
drop policy if exists note_image_occlusion_boxes_owner_select on public.note_image_occlusion_boxes;
create policy note_image_occlusion_boxes_owner_select on public.note_image_occlusion_boxes
  for select using (exists (select 1 from public.notes n where n.id = note_id and n.user_id = auth.uid()));
drop policy if exists note_image_occlusion_boxes_owner_insert on public.note_image_occlusion_boxes;
create policy note_image_occlusion_boxes_owner_insert on public.note_image_occlusion_boxes
  for insert with check (exists (select 1 from public.notes n where n.id = note_id and n.user_id = auth.uid()));
drop policy if exists note_image_occlusion_boxes_owner_update on public.note_image_occlusion_boxes;
create policy note_image_occlusion_boxes_owner_update on public.note_image_occlusion_boxes
  for update using (exists (select 1 from public.notes n where n.id = note_id and n.user_id = auth.uid()))
  with check (exists (select 1 from public.notes n where n.id = note_id and n.user_id = auth.uid()));
drop policy if exists note_image_occlusion_boxes_owner_delete on public.note_image_occlusion_boxes;
create policy note_image_occlusion_boxes_owner_delete on public.note_image_occlusion_boxes
  for delete using (exists (select 1 from public.notes n where n.id = note_id and n.user_id = auth.uid()));

alter table public.note_references enable row level security;
drop policy if exists note_references_source_owner_select on public.note_references;
create policy note_references_source_owner_select on public.note_references
  for select using (
    exists (select 1 from public.notes n where n.id = source_note_id and n.user_id = auth.uid())
    and exists (select 1 from public.notes n where n.id = target_note_id and n.user_id = auth.uid())
  );
drop policy if exists note_references_source_owner_insert on public.note_references;
create policy note_references_source_owner_insert on public.note_references
  for insert with check (
    exists (select 1 from public.notes n where n.id = source_note_id and n.user_id = auth.uid())
    and exists (select 1 from public.notes n where n.id = target_note_id and n.user_id = auth.uid())
  );
drop policy if exists note_references_source_owner_update on public.note_references;
create policy note_references_source_owner_update on public.note_references
  for update using (
    exists (select 1 from public.notes n where n.id = source_note_id and n.user_id = auth.uid())
    and exists (select 1 from public.notes n where n.id = target_note_id and n.user_id = auth.uid())
  )
  with check (
    exists (select 1 from public.notes n where n.id = source_note_id and n.user_id = auth.uid())
    and exists (select 1 from public.notes n where n.id = target_note_id and n.user_id = auth.uid())
  );
drop policy if exists note_references_source_owner_delete on public.note_references;
create policy note_references_source_owner_delete on public.note_references
  for delete using (
    exists (select 1 from public.notes n where n.id = source_note_id and n.user_id = auth.uid())
    and exists (select 1 from public.notes n where n.id = target_note_id and n.user_id = auth.uid())
  );

-- ---------------------------------------------------------------------------
-- USN and tombstones for the new entities.
-- ---------------------------------------------------------------------------
create or replace function public.record_sync_grave()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row jsonb;
  v_old jsonb;
  v_user_id uuid;
  v_entity_key text;
  v_usn bigint;
  v_deleted_at timestamptz;
  v_should_record boolean := false;
  v_note_id uuid;
begin
  v_row := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  v_old := case when tg_op = 'UPDATE' then to_jsonb(old) else '{}'::jsonb end;
  v_deleted_at := nullif(v_row ->> 'deleted_at', '')::timestamptz;
  v_should_record := tg_op = 'DELETE'
    or (tg_op = 'UPDATE' and v_deleted_at is not null and nullif(v_old ->> 'deleted_at', '') is null);
  if not v_should_record then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;

  v_user_id := nullif(v_row ->> 'user_id', '')::uuid;
  if v_user_id is null and tg_argv[0] = 'card_tag' then
    select c.user_id into v_user_id from public.cards c where c.id = (v_row ->> 'card_id')::uuid;
  elsif v_user_id is null and tg_argv[0] = 'note_image_occlusion_box' then
    v_note_id := (v_row ->> 'note_id')::uuid;
    select n.user_id into v_user_id from public.notes n where n.id = v_note_id;
  elsif v_user_id is null and tg_argv[0] = 'note_reference' then
    v_note_id := (v_row ->> 'source_note_id')::uuid;
    select n.user_id into v_user_id from public.notes n where n.id = v_note_id;
  end if;

  v_entity_key := case tg_argv[0]
    when 'user_deck_settings' then concat(v_row ->> 'user_id', ':', v_row ->> 'deck_id')
    when 'daily_statistics' then concat(v_row ->> 'user_id', ':', v_row ->> 'stat_date')
    when 'card_tag' then concat(v_row ->> 'card_id', ':', v_row ->> 'tag_id')
    else nullif(v_row ->> 'id', '')
  end;
  v_usn := nullif(v_row ->> 'usn', '')::bigint;
  if v_user_id is not null and v_entity_key is not null and v_usn is not null then
    insert into public.graves (user_id, entity_type, entity_key, usn, deleted_at)
    values (v_user_id, tg_argv[0], v_entity_key, v_usn, coalesce(v_deleted_at, now()))
    on conflict (user_id, entity_type, entity_key) do update set usn = excluded.usn, deleted_at = excluded.deleted_at;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

alter table public.graves drop constraint if exists graves_entity_type_check;
alter table public.graves add constraint graves_entity_type_check check (entity_type in (
  'deck', 'card', 'note', 'card_template', 'tag', 'card_media', 'card_learning_state', 'review_log',
  'study_settings', 'user_deck_settings', 'daily_statistics', 'note_card_definition', 'note_cloze_deletion',
  'fsrs_optimization_run', 'card_tag', 'ai_ingestion_job', 'note_image_occlusion_box', 'note_reference'
));

do $$
declare v_table text; v_entity text; v_pair text;
begin
  foreach v_pair in array array[
    'ai_ingestion_jobs:ai_ingestion_job',
    'note_image_occlusion_boxes:note_image_occlusion_box',
    'note_references:note_reference'
  ]::text[] loop
    v_table := split_part(v_pair, ':', 1); v_entity := split_part(v_pair, ':', 2);
    execute format('drop trigger if exists %I on public.%I', 'trg_' || v_table || '_sync_usn', v_table);
    execute format('create trigger %I before insert or update on public.%I for each row execute function public.assign_sync_usn()', 'trg_' || v_table || '_sync_usn', v_table);
    execute format('drop trigger if exists %I on public.%I', 'trg_' || v_table || '_sync_grave', v_table);
    execute format('create trigger %I after update or delete on public.%I for each row execute function public.record_sync_grave(%L)', 'trg_' || v_table || '_sync_grave', v_table, v_entity);
  end loop;
end $$;

create index if not exists idx_ai_ingestion_jobs_user_usn on public.ai_ingestion_jobs (user_id, usn);
create index if not exists idx_note_image_occlusion_boxes_usn on public.note_image_occlusion_boxes (note_id, usn);
create index if not exists idx_note_references_usn on public.note_references (source_note_id, usn);

-- ---------------------------------------------------------------------------
-- Transactional image-occlusion materialization.
-- ---------------------------------------------------------------------------
create or replace function public.create_image_occlusion_note(p_note_id uuid, p_boxes jsonb)
returns table (card_id uuid, cloze_ordinal integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_note public.notes%rowtype;
  v_box record;
  v_card_id uuid;
begin
  if v_user_id is null then raise exception 'Authentication is required'; end if;
  if jsonb_typeof(p_boxes) <> 'array' or jsonb_array_length(p_boxes) = 0 then
    raise exception 'p_boxes must be a non-empty JSON array';
  end if;
  select * into v_note from public.notes n where n.id = p_note_id and n.user_id = v_user_id and n.deleted_at is null;
  if not found then raise exception 'Note not found or not owned by current user'; end if;

  for v_box in select * from jsonb_to_recordset(p_boxes) as b(
    cloze_ordinal integer, label_text text, x_pos double precision, y_pos double precision,
    width_pct double precision, height_pct double precision, metadata jsonb
  ) loop
    if v_box.cloze_ordinal is null or v_box.cloze_ordinal <= 0 then raise exception 'cloze_ordinal must be positive'; end if;
    if v_box.x_pos is null or v_box.y_pos is null or v_box.width_pct is null or v_box.height_pct is null
      or v_box.x_pos < 0 or v_box.y_pos < 0 or v_box.width_pct <= 0 or v_box.height_pct <= 0
      or v_box.x_pos + v_box.width_pct > 100 or v_box.y_pos + v_box.height_pct > 100 then
      raise exception 'Image occlusion coordinates must be percentages inside the image';
    end if;

    insert into public.note_image_occlusion_boxes(note_id, cloze_ordinal, label_text, x_pos, y_pos, width_pct, height_pct, metadata)
    values (p_note_id, v_box.cloze_ordinal, v_box.label_text, v_box.x_pos, v_box.y_pos, v_box.width_pct, v_box.height_pct, coalesce(v_box.metadata, '{}'::jsonb))
    on conflict (note_id, cloze_ordinal) do update set
      label_text = excluded.label_text, x_pos = excluded.x_pos, y_pos = excluded.y_pos,
      width_pct = excluded.width_pct, height_pct = excluded.height_pct, metadata = excluded.metadata;

    insert into public.cards(user_id, deck_id, template_id, note_group_id, fields, note_id, card_ordinal, card_kind, cloze_ordinal)
    values (
      v_note.user_id, v_note.deck_id, v_note.template_id, p_note_id,
      jsonb_build_object('Front', coalesce(v_box.label_text, 'Image occlusion'), 'Back', coalesce(v_box.label_text, '')),
      p_note_id, v_box.cloze_ordinal, 'cloze', v_box.cloze_ordinal
    )
    on conflict (note_id, card_ordinal) where deleted_at is null do update set
      fields = excluded.fields, card_kind = excluded.card_kind, cloze_ordinal = excluded.cloze_ordinal,
      template_id = excluded.template_id, updated_at = now(), deleted_at = null
    returning id into v_card_id;

    insert into public.card_learning_state(user_id, card_id, state)
    values (v_user_id, v_card_id, 'new')
    on conflict (user_id, card_id) do nothing;
    card_id := v_card_id; cloze_ordinal := v_box.cloze_ordinal; return next;
  end loop;
end;
$$;
grant execute on function public.create_image_occlusion_note(uuid, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- Incremental sync with ownership-scoped branches for all new entities.
-- ---------------------------------------------------------------------------
create or replace function public.get_incremental_sync(p_after_usn bigint default 0, p_limit integer default 500)
returns table (entity_type text, entity_key text, usn bigint, is_deleted boolean, payload jsonb)
language sql security invoker stable as $$
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
    union all select g.entity_type, g.entity_key, g.usn, true, jsonb_build_object('entity_type', g.entity_type, 'entity_key', g.entity_key, 'deleted_at', g.deleted_at) from public.graves g where g.usn > p_after_usn
  )
  select entity_type, entity_key, usn, is_deleted, payload from changes order by usn asc limit least(greatest(p_limit, 1), 5000);
$$;

comment on function public.create_image_occlusion_note(uuid, jsonb) is 'Creates one cloze card and learning state per image-occlusion box owned by the authenticated user.';
comment on table public.ai_ingestion_jobs is 'Queue contract for asynchronous document-to-notes ingestion; workers own processing and materialization.';
comment on table public.note_references is 'Cross-note links visible to the owner of the source note.';


-- ================= SOURCE 0024_gamification_exams_socratic.sql =================
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


-- ================= SOURCE 0025_user_function_rate_limits.sql =================
-- Flashi 0025: per-user rate limiting for paid-provider Edge Functions.
create table if not exists public.user_function_rate_limits (
  user_id uuid not null references auth.users(id) on delete cascade,
  function_name text not null check (length(function_name) between 1 and 80),
  window_started_at timestamptz not null,
  request_count integer not null default 0 check (request_count >= 0),
  primary key (user_id, function_name, window_started_at)
);

revoke all on table public.user_function_rate_limits from public, anon, authenticated;

create or replace function public.consume_user_rate_limit(
  p_function_name text,
  p_limit integer default 30,
  p_window_seconds integer default 60
)
returns table(allowed boolean, retry_after_seconds integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_window timestamptz;
  v_count integer;
begin
  if v_user_id is null then raise exception 'Authentication is required'; end if;
  if p_function_name is null or p_function_name !~ '^[a-z0-9-]+$' then raise exception 'Invalid function name'; end if;
  if p_limit < 1 or p_limit > 10000 or p_window_seconds < 1 or p_window_seconds > 86400 then raise exception 'Invalid rate limit configuration'; end if;
  v_window := to_timestamp(floor(extract(epoch from clock_timestamp()) / p_window_seconds) * p_window_seconds);
  insert into public.user_function_rate_limits(user_id, function_name, window_started_at, request_count)
  values (v_user_id, p_function_name, v_window, 1)
  on conflict (user_id, function_name, window_started_at) do update
    set request_count = public.user_function_rate_limits.request_count + 1
    where public.user_function_rate_limits.request_count < p_limit
  returning request_count into v_count;
  if v_count is not null and v_count <= p_limit then
    return query select true, 0;
  end if;
  return query select false, greatest(1, ceil(extract(epoch from (v_window + make_interval(secs => p_window_seconds) - clock_timestamp())))::integer);
end;
$$;

revoke execute on function public.consume_user_rate_limit(text, integer, integer) from public, anon;
grant execute on function public.consume_user_rate_limit(text, integer, integer) to authenticated;
comment on function public.consume_user_rate_limit(text, integer, integer) is 'Atomically limits authenticated calls per user and function within a fixed time window.';


-- ================= SOURCE 0026_sdd_ai_worker_gamification_imports.sql =================
-- Flashi 0026: SDD contracts for the asynchronous AI worker, batched XP and imports.
-- Additive and rerunnable. Migration 0025 is reserved for rate limiting.

begin;

-- ---------------------------------------------------------------------------
-- Atomic AI job claim and transactional materialization.
-- ---------------------------------------------------------------------------
create or replace function public.claim_ai_ingestion_job()
returns table (
  job_id uuid,
  user_id uuid,
  deck_id uuid,
  source_type public.generation_source_type,
  source_reference text
)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  with candidate as (
    select j.id
    from public.ai_ingestion_jobs j
    where j.status = 'queued'
      and j.deleted_at is null
    order by j.created_at asc
    limit 1
    for update skip locked
  )
  update public.ai_ingestion_jobs j
  set status = 'processing', updated_at = now(), error_message = null
  from candidate c
  where j.id = c.id
  returning j.id, j.user_id, j.deck_id, j.source_type, j.source_reference;
end;
$$;

create or replace function public.materialize_ai_ingestion_batch(
  p_job_id uuid,
  p_user_id uuid,
  p_deck_id uuid,
  p_notes jsonb
)
returns table (notes_count integer, cards_count integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job public.ai_ingestion_jobs;
  v_note jsonb;
  v_card jsonb;
  v_note_id uuid;
  v_notes integer := 0;
  v_cards integer := 0;
  v_ordinals integer[];
  v_ordinal integer;
  v_fields jsonb;
  v_card_fields jsonb;
  v_kind text;
begin
  if p_user_id is null or p_deck_id is null or p_job_id is null then
    raise exception 'job, user and deck are required';
  end if;
  if jsonb_typeof(p_notes) <> 'array' or jsonb_array_length(p_notes) = 0 then
    raise exception 'notes must be a non-empty JSON array';
  end if;

  select * into v_job
  from public.ai_ingestion_jobs
  where id = p_job_id and user_id = p_user_id and deck_id = p_deck_id
  for update;
  if not found then raise exception 'AI ingestion job not found or ownership mismatch'; end if;
  if v_job.status not in ('processing', 'queued') then raise exception 'AI ingestion job is not materializable'; end if;
  if not exists (select 1 from public.decks where id = p_deck_id and user_id = p_user_id and deleted_at is null) then
    raise exception 'Deck not found or ownership mismatch';
  end if;

  for v_note in select value from jsonb_array_elements(p_notes) loop
    v_fields := v_note -> 'fields';
    if jsonb_typeof(v_fields) <> 'object' or v_fields = '{}'::jsonb then
      raise exception 'Every note must have non-empty fields';
    end if;
    if jsonb_typeof(v_note -> 'cards') <> 'array' or jsonb_array_length(v_note -> 'cards') = 0 then
      raise exception 'Every note must have at least one card';
    end if;

    v_ordinals := '{}';
    insert into public.notes (user_id, deck_id, fields, source)
    values (p_user_id, p_deck_id, v_fields, 'ai_ingestion')
    returning id into v_note_id;
    v_notes := v_notes + 1;

    for v_card in select value from jsonb_array_elements(v_note -> 'cards') loop
      v_card_fields := v_card -> 'fields';
      v_kind := coalesce(v_card ->> 'card_kind', 'basic');
      v_ordinal := (v_card ->> 'card_ordinal')::integer;
      if jsonb_typeof(v_card_fields) <> 'object' or v_card_fields = '{}'::jsonb then
        raise exception 'Every card must have non-empty fields';
      end if;
      if v_kind not in ('basic', 'reverse', 'cloze') then raise exception 'Invalid card_kind'; end if;
      if v_ordinal is null or v_ordinal < 0 then raise exception 'card_ordinal must be non-negative'; end if;
      if v_ordinal = any(v_ordinals) then raise exception 'card_ordinal must be unique within each note'; end if;
      v_ordinals := array_append(v_ordinals, v_ordinal);

      insert into public.cards (
        user_id, deck_id, note_group_id, fields, note_id, card_ordinal, card_kind, cloze_ordinal
      ) values (
        p_user_id, p_deck_id, v_note_id, v_card_fields, v_note_id, v_ordinal, v_kind,
        nullif(v_card ->> 'cloze_ordinal', '')::integer
      );
      v_cards := v_cards + 1;
    end loop;

    insert into public.card_learning_state (user_id, card_id, state)
    select p_user_id, c.id, 'new'
    from public.cards c where c.note_id = v_note_id;
  end loop;

  update public.ai_ingestion_jobs
  set status = 'completed', notes_generated_count = v_notes,
      cards_generated_count = v_cards, updated_at = now(), error_message = null
  where id = p_job_id;
  notes_count := v_notes; cards_count := v_cards; return next;
end;
$$;

-- ---------------------------------------------------------------------------
-- Session XP: idempotent batching instead of per-review triggers.
-- ---------------------------------------------------------------------------
create table if not exists public.gamification_xp_sessions (
  user_id uuid not null references auth.users(id) on delete cascade,
  session_id uuid not null,
  xp_awarded integer not null check (xp_awarded >= 0),
  review_count integer not null check (review_count >= 0),
  synced_at timestamptz not null default now(),
  primary key (user_id, session_id)
);
revoke all on table public.gamification_xp_sessions from public, anon, authenticated;

create or replace function public.sync_session_xp(p_session_id uuid)
returns table (session_id uuid, review_count integer, xp_awarded integer, xp_total integer, level_current integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_count integer;
  v_xp integer;
  v_profile public.user_gamification_profiles;
  v_existing public.gamification_xp_sessions;
  v_bonus numeric := 0;
begin
  if v_user_id is null or p_session_id is null then raise exception 'Authentication and session_id are required'; end if;
  select * into v_existing from public.gamification_xp_sessions where user_id = v_user_id and gamification_xp_sessions.session_id = p_session_id;
  if found then
    select * into v_profile from public.user_gamification_profiles where user_id = v_user_id;
    return query select p_session_id, v_existing.review_count, v_existing.xp_awarded, v_profile.xp_total, v_profile.level_current;
    return;
  end if;
  select count(*)::integer into v_count from public.review_logs where user_id = v_user_id and session_id = p_session_id;
  if v_count = 0 then raise exception 'Study session has no reviews'; end if;
  select coalesce(streak_days_count, 0) * 0.01 into v_bonus from public.user_gamification_profiles where user_id = v_user_id;
  select coalesce(sum(case rating when 'again' then 1 when 'hard' then 3 when 'good' then 5 when 'easy' then 7 end), 0)::integer into v_xp
  from public.review_logs where user_id = v_user_id and session_id = p_session_id;
  v_xp := greatest(1, round(v_xp * (1 + least(v_bonus, 0.5)))::integer);

  insert into public.user_gamification_profiles(user_id) values (v_user_id) on conflict do nothing;
  update public.user_gamification_profiles
  set xp_total = xp_total + v_xp,
      level_current = greatest(1, floor(sqrt((xp_total + v_xp)::numeric / 100.0))::integer + 1),
      updated_at = now()
  where user_id = v_user_id returning * into v_profile;
  insert into public.gamification_xp_sessions(user_id, session_id, xp_awarded, review_count)
  values (v_user_id, p_session_id, v_xp, v_count);
  return query select p_session_id, v_count, v_xp, v_profile.xp_total, v_profile.level_current;
end;
$$;

-- A periodically refreshed projection for fast home-screen leaderboards.
create materialized view if not exists public.leaderboard_entries as
select row_number() over (order by g.xp_total desc, g.updated_at asc) as rank,
       g.user_id, p.display_name, g.xp_total, g.level_current, g.updated_at
from public.user_gamification_profiles g
left join public.profiles p on p.id = g.user_id;
create unique index if not exists idx_leaderboard_entries_user on public.leaderboard_entries(user_id);

-- ---------------------------------------------------------------------------
-- File imports use a signed Storage URL and the same materialization RPC.
-- ---------------------------------------------------------------------------
create table if not exists public.deck_import_jobs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  deck_id uuid not null references public.decks(id) on delete cascade,
  format text not null check (format in ('csv', 'markdown', 'quizlet', 'remnote')),
  storage_path text not null,
  status public.job_status_type not null default 'queued',
  imported_notes integer not null default 0,
  imported_cards integer not null default 0,
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_deck_import_jobs_user_created on public.deck_import_jobs(user_id, created_at desc);
alter table public.deck_import_jobs enable row level security;
drop policy if exists deck_import_jobs_owner_all on public.deck_import_jobs;
create policy deck_import_jobs_owner_all on public.deck_import_jobs for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

create or replace function public.materialize_import_batch(
  p_job_id uuid,
  p_user_id uuid,
  p_deck_id uuid,
  p_notes jsonb
)
returns table (notes_count integer, cards_count integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_import public.deck_import_jobs;
  v_ai_job uuid;
  v_result record;
begin
  if auth.uid() is null or auth.uid() <> p_user_id then raise exception 'Only the authenticated owner can import a deck'; end if;
  select * into v_import from public.deck_import_jobs where id = p_job_id and user_id = p_user_id and deck_id = p_deck_id for update;
  if not found then raise exception 'Import job not found or ownership mismatch'; end if;
  insert into public.ai_ingestion_jobs(user_id, deck_id, source_type, source_reference, status)
  values (p_user_id, p_deck_id, 'raw_text_block', 'import:' || p_job_id::text, 'processing') returning id into v_ai_job;
  select * into v_result from public.materialize_ai_ingestion_batch(v_ai_job, p_user_id, p_deck_id, p_notes);
  update public.deck_import_jobs set status = 'completed', imported_notes = v_result.notes_count, imported_cards = v_result.cards_count, updated_at = now() where id = p_job_id;
  notes_count := v_result.notes_count; cards_count := v_result.cards_count; return next;
exception when others then
  update public.deck_import_jobs set status = 'failed', error_message = left(sqlerrm, 500), updated_at = now() where id = p_job_id;
  raise;
end;
$$;

grant execute on function public.materialize_import_batch(uuid, uuid, uuid, jsonb) to authenticated;

revoke execute on function public.claim_ai_ingestion_job() from public, anon, authenticated;
revoke execute on function public.materialize_ai_ingestion_batch(uuid, uuid, uuid, jsonb) from public, anon, authenticated;
revoke execute on function public.sync_session_xp(uuid) from public, anon;
grant execute on function public.sync_session_xp(uuid) to authenticated;

comment on function public.claim_ai_ingestion_job() is 'Atomically claims the oldest queued AI ingestion job with FOR UPDATE SKIP LOCKED; service worker only.';
comment on function public.materialize_ai_ingestion_batch(uuid, uuid, uuid, jsonb) is 'Validates and materializes AI notes/cards in one transaction, then completes the job.';
comment on function public.sync_session_xp(uuid) is 'Idempotently batches session XP using rating weights and a streak bonus.';
comment on materialized view public.leaderboard_entries is 'Refresh periodically outside request path: REFRESH MATERIALIZED VIEW CONCURRENTLY public.leaderboard_entries.';

commit;

