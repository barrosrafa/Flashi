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
