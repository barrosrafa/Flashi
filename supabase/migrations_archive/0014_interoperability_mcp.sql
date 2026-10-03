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
