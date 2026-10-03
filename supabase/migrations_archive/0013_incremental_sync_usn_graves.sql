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
