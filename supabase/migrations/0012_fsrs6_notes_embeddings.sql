-- Flashi 0012: FSRS-6, explicit note -> card generation, Cloze support,
-- semantic embeddings and media integrity metadata.
--
-- The database persists the FSRS-6 state and optimization inputs. The actual
-- scheduler/optimizer remains in the application or Edge Function layer so
-- the implementation can be tested and upgraded independently of PostgreSQL.

-- Supabase exposes pgvector through the extensions schema.
create extension if not exists vector with schema extensions;

-- ---------------------------------------------------------------------------
-- Notes are facts/content. Cards are independent review exercises generated
-- from a note. Existing cards are migrated from note_group_id, preserving IDs.
-- ---------------------------------------------------------------------------
create table if not exists public.notes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  deck_id uuid not null references public.decks(id) on delete cascade,
  template_id uuid references public.card_templates(id) on delete set null,
  fields jsonb not null default '{}'::jsonb,
  source text,
  embedding extensions.vector(1536),
  embedding_model text,
  embedding_updated_at timestamptz,
  search_document tsvector generated always as (
    jsonb_to_tsvector('simple'::regconfig, fields, '["string"]'::jsonb)
  ) stored,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint notes_fields_not_empty check (fields <> '{}'::jsonb)
);

create index if not exists idx_notes_user on public.notes (user_id)
  where deleted_at is null;
create index if not exists idx_notes_deck on public.notes (deck_id)
  where deleted_at is null;
create index if not exists idx_notes_search_document
  on public.notes using gin (search_document);
create index if not exists idx_notes_embedding_hnsw
  on public.notes using hnsw (embedding extensions.vector_cosine_ops)
  where embedding is not null;

alter table public.cards add column if not exists note_id uuid;
alter table public.cards add column if not exists card_ordinal integer not null default 0;
alter table public.cards add column if not exists card_kind text not null default 'basic';
alter table public.cards add column if not exists cloze_ordinal integer;

-- One legacy note is created for every historical note_group_id. DISTINCT ON
-- keeps the earliest card's fields as the canonical note content.
insert into public.notes (
  id, user_id, deck_id, template_id, fields, created_at, updated_at, deleted_at
)
select distinct on (c.note_group_id)
  c.note_group_id,
  c.user_id,
  c.deck_id,
  c.template_id,
  c.fields,
  c.created_at,
  c.updated_at,
  c.deleted_at
from public.cards c
where c.note_group_id is not null
order by c.note_group_id, c.created_at asc, c.id asc
on conflict (id) do nothing;

update public.cards c
set note_id = c.note_group_id
where c.note_id is null;

-- Stable ordinals allow one note to generate Basic, Reverse and multiple Cloze
-- cards independently. Existing cards receive deterministic ordinals.
with ranked as (
  select c.id,
         row_number() over (
           partition by c.note_id order by c.created_at asc, c.id asc
         ) - 1 as ordinal
  from public.cards c
)
update public.cards c
set card_ordinal = ranked.ordinal
from ranked
where c.id = ranked.id;

alter table public.cards alter column note_id set not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'cards_note_id_fkey'
      and conrelid = 'public.cards'::regclass
  ) then
    alter table public.cards
      add constraint cards_note_id_fkey
      foreign key (note_id) references public.notes(id) on delete cascade;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'cards_card_kind_check'
      and conrelid = 'public.cards'::regclass
  ) then
    alter table public.cards
      add constraint cards_card_kind_check check (
        card_kind in ('basic', 'reverse', 'cloze')
        and (card_kind <> 'cloze' or cloze_ordinal is not null)
        and (cloze_ordinal is null or cloze_ordinal > 0)
      );
  end if;
end $$;

create unique index if not exists cards_unique_note_ordinal
  on public.cards (note_id, card_ordinal)
  where deleted_at is null;
create index if not exists idx_cards_note_kind
  on public.cards (note_id, card_kind)
  where deleted_at is null;

-- Relational definitions complement card_templates.card_generation JSONB and
-- make generated card types explicit and independently addressable.
create table if not exists public.note_card_definitions (
  id uuid primary key default gen_random_uuid(),
  template_id uuid not null references public.card_templates(id) on delete cascade,
  ordinal integer not null check (ordinal >= 0),
  name text not null check (char_length(name) between 1 and 120),
  card_kind text not null default 'basic',
  front_template text not null,
  back_template text not null,
  cloze_ordinal integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint note_card_definitions_kind_check check (
    card_kind in ('basic', 'reverse', 'cloze')
    and (card_kind <> 'cloze' or cloze_ordinal is not null)
    and (cloze_ordinal is null or cloze_ordinal > 0)
  ),
  unique (template_id, ordinal)
);

create index if not exists idx_note_card_definitions_template
  on public.note_card_definitions (template_id, ordinal);

-- Explicit Cloze metadata. The source answer remains in notes.fields; these
-- rows identify each deletion and let the client render c1, c2, ... cards.
create table if not exists public.note_cloze_deletions (
  id uuid primary key default gen_random_uuid(),
  note_id uuid not null references public.notes(id) on delete cascade,
  field_name text not null,
  cloze_ordinal integer not null check (cloze_ordinal > 0),
  hint text,
  start_offset integer,
  end_offset integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (note_id, field_name, cloze_ordinal)
);

create index if not exists idx_note_cloze_note on public.note_cloze_deletions (note_id);

-- Media stays in Supabase Storage. The database stores only the pointer,
-- metadata and a digest that the upload worker can verify.
alter table public.card_media add column if not exists md5_hash text;
alter table public.card_media add column if not exists storage_bucket text not null default 'card-media';

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'card_media_md5_hash_check'
      and conrelid = 'public.card_media'::regclass
  ) then
    alter table public.card_media add constraint card_media_md5_hash_check
      check (md5_hash is null or md5_hash ~ '^[0-9a-fA-F]{32}$');
  end if;
end $$;

create index if not exists idx_card_media_integrity
  on public.card_media (user_id, md5_hash)
  where md5_hash is not null;

-- ---------------------------------------------------------------------------
-- FSRS-6 persistence and optimization.
-- ---------------------------------------------------------------------------
alter table public.study_settings
  add column if not exists fsrs_version text not null default 'fsrs-6';
alter table public.study_settings
  add column if not exists fsrs_desired_retention numeric(5,4) not null default 0.9000;
alter table public.study_settings
  add column if not exists fsrs_maximum_interval_days integer not null default 36500;
alter table public.study_settings
  add column if not exists fsrs_weights numeric[] not null default '{}'::numeric[];
alter table public.study_settings
  add column if not exists fsrs_optimizer_threshold integer not null default 1000;
alter table public.study_settings
  add column if not exists fsrs_last_optimized_at timestamptz;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'study_settings_fsrs_retention_check'
      and conrelid = 'public.study_settings'::regclass
  ) then
    alter table public.study_settings add constraint study_settings_fsrs_retention_check
      check (fsrs_desired_retention > 0.5 and fsrs_desired_retention < 1.0);
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'study_settings_fsrs_weights_check'
      and conrelid = 'public.study_settings'::regclass
  ) then
    alter table public.study_settings add constraint study_settings_fsrs_weights_check
      check (cardinality(fsrs_weights) in (0, 21));
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'study_settings_fsrs_threshold_check'
      and conrelid = 'public.study_settings'::regclass
  ) then
    alter table public.study_settings add constraint study_settings_fsrs_threshold_check
      check (fsrs_optimizer_threshold >= 100);
  end if;
end $$;

alter table public.card_learning_state
  add column if not exists fsrs_version text not null default 'fsrs-6';
alter table public.card_learning_state
  add column if not exists fsrs_state smallint not null default 0;
alter table public.card_learning_state
  add column if not exists fsrs_step integer;
alter table public.card_learning_state
  add column if not exists fsrs_retrievability numeric(8,6);
alter table public.card_learning_state
  add column if not exists fsrs_last_scheduled_at timestamptz;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'card_learning_state_fsrs_state_check'
      and conrelid = 'public.card_learning_state'::regclass
  ) then
    alter table public.card_learning_state add constraint card_learning_state_fsrs_state_check
      check (fsrs_state between 0 and 3);
  end if;
end $$;

alter table public.review_logs
  add column if not exists fsrs_version text not null default 'fsrs-6';
alter table public.review_logs
  add column if not exists elapsed_days integer;
alter table public.review_logs
  add column if not exists scheduled_days integer;
alter table public.review_logs
  add column if not exists fsrs_retrievability numeric(8,6);
alter table public.review_logs
  add column if not exists fsrs_parameter_version integer;

create table if not exists public.fsrs_optimization_runs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  source_review_count integer not null check (source_review_count >= 0),
  status text not null default 'queued',
  old_weights numeric[] not null default '{}'::numeric[],
  new_weights numeric[] not null default '{}'::numeric[],
  old_loss numeric,
  new_loss numeric,
  requested_at timestamptz not null default now(),
  started_at timestamptz,
  completed_at timestamptz,
  error_message text,
  unique (user_id, source_review_count),
  constraint fsrs_optimization_status_check check (
    status in ('queued', 'running', 'completed', 'failed', 'cancelled')
  )
);

create index if not exists idx_fsrs_optimization_user_status
  on public.fsrs_optimization_runs (user_id, status, requested_at desc);

create or replace function public.get_fsrs_optimization_status()
returns table (
  review_count bigint,
  optimizer_threshold integer,
  is_ready boolean,
  has_queued_run boolean,
  last_optimized_at timestamptz
)
language sql
security invoker
stable
as $$
  select
    count(r.id) as review_count,
    coalesce(s.fsrs_optimizer_threshold, 1000) as optimizer_threshold,
    count(r.id) >= coalesce(s.fsrs_optimizer_threshold, 1000) as is_ready,
    exists (
      select 1 from public.fsrs_optimization_runs o
      where o.user_id = auth.uid() and o.status in ('queued', 'running')
    ) as has_queued_run,
    s.fsrs_last_optimized_at
  from (select auth.uid() as user_id) u
  left join public.study_settings s on s.user_id = u.user_id
  left join public.review_logs r
    on r.user_id = u.user_id and r.algorithm = 'fsrs'
  group by s.fsrs_optimizer_threshold, s.fsrs_last_optimized_at;
$$;

create or replace function public.enqueue_fsrs_optimization()
returns uuid
language plpgsql
security invoker
as $$
declare
  v_user_id uuid := auth.uid();
  v_count integer;
  v_threshold integer;
  v_run_id uuid;
  v_weights numeric[];
begin
  if v_user_id is null then
    raise exception 'Authentication is required';
  end if;

  select count(*)::integer into v_count
  from public.review_logs
  where user_id = v_user_id and algorithm = 'fsrs';

  select fsrs_optimizer_threshold, fsrs_weights
    into v_threshold, v_weights
  from public.study_settings
  where user_id = v_user_id;

  v_threshold := coalesce(v_threshold, 1000);
  if v_count < v_threshold then
    raise exception 'FSRS optimization requires at least % FSRS reviews; found %',
      v_threshold, v_count;
  end if;

  select id into v_run_id
  from public.fsrs_optimization_runs
  where user_id = v_user_id and source_review_count = v_count;

  if v_run_id is not null then
    return v_run_id;
  end if;

  insert into public.fsrs_optimization_runs (
    user_id, source_review_count, old_weights
  ) values (
    v_user_id, v_count, coalesce(v_weights, '{}'::numeric[])
  ) returning id into v_run_id;

  return v_run_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Semantic duplicate detection and meaning search.
-- The embedding dimension is intentionally explicit and matches the default
-- text-embedding-3-small contract used by the application layer.
-- ---------------------------------------------------------------------------
create or replace function public.search_notes_by_embedding(
  p_query_embedding extensions.vector(1536),
  p_match_threshold real default 0.78,
  p_limit integer default 20
)
returns table (
  note_id uuid,
  deck_id uuid,
  fields jsonb,
  similarity real
)
language sql
security invoker
stable
set search_path = public, extensions
as $$
  select n.id,
         n.deck_id,
         n.fields,
         (1 - (n.embedding <=> p_query_embedding))::real as similarity
  from public.notes n
  where n.user_id = auth.uid()
    and n.deleted_at is null
    and n.embedding is not null
    and (1 - (n.embedding <=> p_query_embedding)) >= p_match_threshold
  order by n.embedding <=> p_query_embedding
  limit least(greatest(p_limit, 1), 100);
$$;

create or replace function public.find_similar_notes(
  p_note_id uuid,
  p_match_threshold real default 0.90,
  p_limit integer default 5
)
returns table (
  note_id uuid,
  deck_id uuid,
  fields jsonb,
  similarity real
)
language sql
security invoker
stable
set search_path = public, extensions
as $$
  select n2.id,
         n2.deck_id,
         n2.fields,
         (1 - (n2.embedding <=> n1.embedding))::real as similarity
  from public.notes n1
  join public.notes n2
    on n2.user_id = n1.user_id
   and n2.id <> n1.id
   and n2.deleted_at is null
   and n2.embedding is not null
  where n1.id = p_note_id
    and n1.user_id = auth.uid()
    and n1.deleted_at is null
    and n1.embedding is not null
    and (1 - (n2.embedding <=> n1.embedding)) >= p_match_threshold
  order by n2.embedding <=> n1.embedding
  limit least(greatest(p_limit, 1), 100);
$$;

-- ---------------------------------------------------------------------------
-- RLS for the new user-owned entities.
-- ---------------------------------------------------------------------------
alter table public.notes enable row level security;
alter table public.note_card_definitions enable row level security;
alter table public.note_cloze_deletions enable row level security;
alter table public.fsrs_optimization_runs enable row level security;

drop policy if exists notes_owner on public.notes;
create policy notes_owner on public.notes
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists note_card_definitions_read on public.note_card_definitions;
create policy note_card_definitions_read on public.note_card_definitions
  for select using (
    exists (
      select 1 from public.card_templates t
      where t.id = note_card_definitions.template_id
        and (t.user_id = auth.uid() or t.is_system = true)
    )
  );

drop policy if exists note_card_definitions_owner on public.note_card_definitions;
create policy note_card_definitions_owner on public.note_card_definitions
  for insert with check (
    exists (
      select 1 from public.card_templates t
      where t.id = note_card_definitions.template_id
        and t.user_id = auth.uid()
    )
  );

create policy note_card_definitions_update on public.note_card_definitions
  for update using (
    exists (
      select 1 from public.card_templates t
      where t.id = note_card_definitions.template_id and t.user_id = auth.uid()
    )
  ) with check (
    exists (
      select 1 from public.card_templates t
      where t.id = note_card_definitions.template_id and t.user_id = auth.uid()
    )
  );

create policy note_card_definitions_delete on public.note_card_definitions
  for delete using (
    exists (
      select 1 from public.card_templates t
      where t.id = note_card_definitions.template_id and t.user_id = auth.uid()
    )
  );

drop policy if exists note_cloze_deletions_owner on public.note_cloze_deletions;
create policy note_cloze_deletions_owner on public.note_cloze_deletions
  for all using (
    exists (select 1 from public.notes n where n.id = note_id and n.user_id = auth.uid())
  ) with check (
    exists (select 1 from public.notes n where n.id = note_id and n.user_id = auth.uid())
  );

drop policy if exists fsrs_optimization_runs_owner on public.fsrs_optimization_runs;
create policy fsrs_optimization_runs_owner on public.fsrs_optimization_runs
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- updated_at for new mutable tables.
drop trigger if exists trg_notes_updated_at on public.notes;
create trigger trg_notes_updated_at before update on public.notes
  for each row execute function public.set_updated_at();

drop trigger if exists trg_note_card_definitions_updated_at on public.note_card_definitions;
create trigger trg_note_card_definitions_updated_at before update on public.note_card_definitions
  for each row execute function public.set_updated_at();

drop trigger if exists trg_note_cloze_deletions_updated_at on public.note_cloze_deletions;
create trigger trg_note_cloze_deletions_updated_at before update on public.note_cloze_deletions
  for each row execute function public.set_updated_at();
