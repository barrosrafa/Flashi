-- Flashi 0018: AI document ingestion jobs, image occlusion and note references.
-- This migration is additive and safe to rerun after 0017.

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
  for select using (exists (select 1 from public.notes n where n.id = source_note_id and n.user_id = auth.uid()));
drop policy if exists note_references_source_owner_insert on public.note_references;
create policy note_references_source_owner_insert on public.note_references
  for insert with check (exists (select 1 from public.notes n where n.id = source_note_id and n.user_id = auth.uid()));
drop policy if exists note_references_source_owner_update on public.note_references;
create policy note_references_source_owner_update on public.note_references
  for update using (exists (select 1 from public.notes n where n.id = source_note_id and n.user_id = auth.uid()))
  with check (exists (select 1 from public.notes n where n.id = source_note_id and n.user_id = auth.uid()));
drop policy if exists note_references_source_owner_delete on public.note_references;
create policy note_references_source_owner_delete on public.note_references
  for delete using (exists (select 1 from public.notes n where n.id = source_note_id and n.user_id = auth.uid()));

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
  with changes as (
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
