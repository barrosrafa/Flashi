-- Flashi F18/F19/F20/F46: percentage-safe image occlusion and owned media lifecycle.
-- This migration is additive and keeps the legacy two-argument RPC available for
-- older clients while the five-argument RPC provides the durable contract.

create table if not exists public.image_occlusion_assets (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  deck_id uuid not null references public.decks(id) on delete cascade,
  note_id uuid not null references public.notes(id) on delete cascade,
  storage_bucket text not null default 'card-media',
  storage_path text not null,
  file_size_bytes bigint not null check (file_size_bytes between 1 and 26214400),
  mime_type text not null,
  masks jsonb not null default '[]'::jsonb,
  status text not null default 'staged',
  last_request_id text,
  created_at timestamptz not null default now(),
  associated_at timestamptz,
  constraint image_occlusion_assets_status_check check (status in ('staged', 'associated', 'deleted')),
  constraint image_occlusion_assets_masks_check check (jsonb_typeof(masks) = 'array'),
  constraint image_occlusion_assets_bucket_check check (storage_bucket = 'card-media'),
  constraint image_occlusion_assets_path_owner_check check (storage_path like user_id::text || '/%'),
  constraint image_occlusion_assets_mime_check check (mime_type in (
    'image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/avif', 'image/svg+xml'
  ))
);

create index if not exists idx_image_occlusion_assets_owner_status
  on public.image_occlusion_assets (user_id, status, created_at desc);
create index if not exists idx_image_occlusion_assets_note
  on public.image_occlusion_assets (note_id, deck_id);

alter table public.card_media add column if not exists asset_id uuid;

-- Existing rows may predate strict upload metadata. New rows and staged assets are
-- checked by NOT NULL constraints above and by the storage policy below.
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'card_media_asset_id_fkey'
      and conrelid = 'public.card_media'::regclass
  ) then
    alter table public.card_media
      add constraint card_media_asset_id_fkey
      foreign key (asset_id) references public.image_occlusion_assets(id);
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'card_media_mime_type_check'
      and conrelid = 'public.card_media'::regclass
  ) then
    alter table public.card_media add constraint card_media_mime_type_check check (
      mime_type is null or mime_type in (
        'image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/avif', 'image/svg+xml',
        'audio/mpeg', 'audio/ogg', 'audio/wav', 'audio/webm', 'audio/mp4',
        'video/mp4', 'video/webm', 'video/quicktime'
      )
    );
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'card_media_file_size_check'
      and conrelid = 'public.card_media'::regclass
  ) then
    alter table public.card_media add constraint card_media_file_size_check check (
      file_size_bytes is null or file_size_bytes between 1 and 26214400
    );
  end if;
end $$;

alter table public.image_occlusion_assets enable row level security;
drop policy if exists image_occlusion_assets_owner on public.image_occlusion_assets;
create policy image_occlusion_assets_owner on public.image_occlusion_assets
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

create or replace function public.media_storage_metadata_allowed(p_metadata jsonb)
returns boolean
language plpgsql
immutable
set search_path = public
as $$
declare
  v_mime text := lower(coalesce(p_metadata->>'mimetype', p_metadata->>'mimeType', ''));
  v_size text := coalesce(p_metadata->>'size', '');
begin
  return v_mime in (
      'image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/avif', 'image/svg+xml',
      'audio/mpeg', 'audio/ogg', 'audio/wav', 'audio/webm', 'audio/mp4',
      'video/mp4', 'video/webm', 'video/quicktime'
    )
    and v_size ~ '^[0-9]+$'
    and v_size::bigint between 1 and 26214400;
end;
$$;

-- Storage metadata is checked as well as the database row. The first path
-- segment remains the authenticated owner and staging paths are user-scoped.
drop policy if exists "card_media_storage_owner_select" on storage.objects;
create policy "card_media_storage_owner_select" on storage.objects
  for select using (
    bucket_id = 'card-media'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
drop policy if exists "card_media_storage_owner_insert" on storage.objects;
create policy "card_media_storage_owner_insert" on storage.objects
  for insert with check (
    bucket_id = 'card-media'
    and (storage.foldername(name))[1] = auth.uid()::text
    and public.media_storage_metadata_allowed(metadata)
  );
drop policy if exists "card_media_storage_owner_update" on storage.objects;
create policy "card_media_storage_owner_update" on storage.objects
  for update using (
    bucket_id = 'card-media'
    and (storage.foldername(name))[1] = auth.uid()::text
  ) with check (
    bucket_id = 'card-media'
    and (storage.foldername(name))[1] = auth.uid()::text
    and public.media_storage_metadata_allowed(metadata)
  );
drop policy if exists "card_media_storage_owner_delete" on storage.objects;
create policy "card_media_storage_owner_delete" on storage.objects
  for delete using (
    bucket_id = 'card-media'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create or replace function public.stage_image_occlusion_asset(
  p_asset_id uuid,
  p_deck_id uuid,
  p_note_id uuid,
  p_storage_bucket text,
  p_storage_path text,
  p_mime_type text,
  p_file_size_bytes bigint
)
returns public.image_occlusion_assets
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_asset public.image_occlusion_assets%rowtype;
begin
  if v_user_id is null then raise exception 'AUTH_REQUIRED' using errcode = '28000'; end if;
  if p_storage_bucket <> 'card-media' or p_storage_path not like v_user_id::text || '/%' then
    raise exception 'MEDIA_STORAGE_PATH_NOT_OWNED' using errcode = 'P0001';
  end if;
  if p_mime_type not in ('image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/avif', 'image/svg+xml') then
    raise exception 'MEDIA_MIME_NOT_ALLOWED' using errcode = 'P0001';
  end if;
  if p_file_size_bytes is null or p_file_size_bytes < 1 or p_file_size_bytes > 26214400 then
    raise exception 'MEDIA_SIZE_NOT_ALLOWED' using errcode = 'P0001';
  end if;
  if not exists (
    select 1
    from public.notes n
    join public.decks d on d.id = n.deck_id and d.id = p_deck_id
    where n.id = p_note_id and n.user_id = v_user_id and n.deck_id = p_deck_id
      and n.deleted_at is null and d.user_id = v_user_id and d.deleted_at is null
  ) then
    raise exception 'OCCLUSION_NOTE_OR_DECK_NOT_OWNED' using errcode = 'P0001';
  end if;

  insert into public.image_occlusion_assets(
    id, user_id, deck_id, note_id, storage_bucket, storage_path, file_size_bytes, mime_type
  ) values (
    p_asset_id, v_user_id, p_deck_id, p_note_id, p_storage_bucket, p_storage_path,
    p_file_size_bytes, p_mime_type
  ) returning * into v_asset;
  return v_asset;
end;
$$;
revoke execute on function public.stage_image_occlusion_asset(uuid, uuid, uuid, text, text, text, bigint) from public, anon;
grant execute on function public.stage_image_occlusion_asset(uuid, uuid, uuid, text, text, text, bigint) to authenticated;

-- Five arguments make asset, note, deck and request correlation mandatory for the
-- new flow. The legacy two-argument function remains available to old clients.
create or replace function public.create_image_occlusion_note(
  p_note_id uuid,
  p_boxes jsonb,
  p_asset_id uuid,
  p_deck_id uuid,
  p_request_id text
)
returns table (
  card_id uuid,
  cloze_ordinal integer,
  asset_id uuid,
  note_id uuid,
  deck_id uuid,
  status text,
  code text,
  request_id text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_note public.notes%rowtype;
  v_asset public.image_occlusion_assets%rowtype;
  v_box record;
  v_card_id uuid;
  v_request_id text := left(coalesce(nullif(trim(p_request_id), ''), gen_random_uuid()::text), 200);
  v_ordinal integer;
begin
  if v_user_id is null then raise exception 'AUTH_REQUIRED' using errcode = '28000'; end if;
  if p_asset_id is null then raise exception 'OCCLUSION_ASSET_REQUIRED' using errcode = 'P0001', detail = 'request_id=' || v_request_id; end if;
  if p_deck_id is null then raise exception 'OCCLUSION_DECK_REQUIRED' using errcode = 'P0001', detail = 'request_id=' || v_request_id; end if;
  if jsonb_typeof(p_boxes) <> 'array' or jsonb_array_length(p_boxes) = 0 then
    raise exception 'OCCLUSION_MASKS_REQUIRED' using errcode = 'P0001', detail = 'request_id=' || v_request_id;
  end if;

  select * into v_note
  from public.notes n
  where n.id = p_note_id and n.deck_id = p_deck_id and n.user_id = v_user_id and n.deleted_at is null for update;
  if not found then raise exception 'OCCLUSION_NOTE_OR_DECK_NOT_OWNED' using errcode = 'P0001', detail = 'request_id=' || v_request_id; end if;

  select * into v_asset
  from public.image_occlusion_assets a
  where a.id = p_asset_id and a.user_id = v_user_id and a.note_id = p_note_id
    and a.deck_id = p_deck_id and a.status in ('staged', 'associated')
  for update;
  if not found then raise exception 'OCCLUSION_ASSET_NOT_FOUND_OR_NOT_OWNED' using errcode = 'P0001', detail = 'request_id=' || v_request_id; end if;

  if v_asset.status = 'associated' then
    return query
      select c.id, c.cloze_ordinal, p_asset_id, p_note_id, p_deck_id,
             'already_created'::text, 'OCCLUSION_CARDS_ALREADY_CREATED'::text,
             coalesce(v_asset.last_request_id, v_request_id)
      from public.cards c
      join public.card_media cm on cm.card_id = c.id and cm.asset_id = p_asset_id
      where c.note_id = p_note_id and c.user_id = v_user_id and c.deleted_at is null
      order by c.cloze_ordinal;
    return;
  end if;

  v_ordinal:=coalesce((select max(card_ordinal)+1 from public.cards where note_id=p_note_id and deleted_at is null),0);
  for v_box in select * from jsonb_to_recordset(p_boxes) as b(
    cloze_ordinal integer, label_text text, x_pos double precision, y_pos double precision,
    width_pct double precision, height_pct double precision, metadata jsonb
  ) loop
    if v_box.cloze_ordinal is null or v_box.cloze_ordinal <= 0 then
      raise exception 'OCCLUSION_CLOZE_ORDINAL_INVALID' using errcode = 'P0001', detail = 'request_id=' || v_request_id;
    end if;
    if v_box.x_pos is null or v_box.y_pos is null or v_box.width_pct is null or v_box.height_pct is null
      or v_box.x_pos < 0 or v_box.y_pos < 0 or v_box.width_pct <= 0 or v_box.height_pct <= 0
      or v_box.x_pos + v_box.width_pct > 100 or v_box.y_pos + v_box.height_pct > 100 then
      raise exception 'OCCLUSION_MASKS_MUST_BE_PERCENTAGES' using errcode = 'P0001', detail = 'request_id=' || v_request_id;
    end if;
  end loop;

  delete from public.note_image_occlusion_boxes b
  where b.note_id = p_note_id
    and not exists (
      select 1 from jsonb_to_recordset(p_boxes) as keep(cloze_ordinal integer)
      where keep.cloze_ordinal = b.cloze_ordinal
    );

  for v_box in select * from jsonb_to_recordset(p_boxes) as b(
    cloze_ordinal integer, label_text text, x_pos double precision, y_pos double precision,
    width_pct double precision, height_pct double precision, metadata jsonb
  ) loop
    insert into public.note_image_occlusion_boxes(note_id, cloze_ordinal, label_text, x_pos, y_pos, width_pct, height_pct, metadata)
    values (p_note_id, v_box.cloze_ordinal, v_box.label_text, v_box.x_pos, v_box.y_pos, v_box.width_pct, v_box.height_pct, coalesce(v_box.metadata, '{}'::jsonb))
    on conflict (note_id, cloze_ordinal) do update set
      label_text = excluded.label_text, x_pos = excluded.x_pos, y_pos = excluded.y_pos,
      width_pct = excluded.width_pct, height_pct = excluded.height_pct, metadata = excluded.metadata;

    insert into public.cards(user_id, deck_id, template_id, note_group_id, fields, note_id, card_ordinal, card_kind, cloze_ordinal)
    values (
      v_user_id, p_deck_id, v_note.template_id, p_note_id,
      jsonb_build_object('Front', coalesce(v_box.label_text, 'Image occlusion'), 'Back', coalesce(v_box.label_text, '')),
      p_note_id, v_ordinal, 'cloze', v_box.cloze_ordinal
    )
    on conflict (note_id, card_ordinal) where deleted_at is null do update set
      fields = excluded.fields, card_kind = excluded.card_kind, cloze_ordinal = excluded.cloze_ordinal,
      template_id = excluded.template_id, updated_at = now(), deleted_at = null
    returning id into v_card_id;

    insert into public.card_learning_state(user_id, card_id, state)
    values (v_user_id, v_card_id, 'new')
    on conflict (user_id, card_id) do nothing;

    insert into public.card_media(
      card_id, user_id, field_name, media_type, storage_path, storage_bucket,
      file_size_bytes, mime_type, metadata, asset_id
    ) values (
      v_card_id, v_user_id, 'Front', 'image', v_asset.storage_path, v_asset.storage_bucket,
      v_asset.file_size_bytes, v_asset.mime_type,
      jsonb_build_object('asset_id', p_asset_id, 'occlusion', true), p_asset_id
    )
    on conflict do nothing;

    v_ordinal:=v_ordinal+1;
    card_id := v_card_id;
    cloze_ordinal := v_box.cloze_ordinal;
    asset_id := p_asset_id;
    note_id := p_note_id;
    deck_id := p_deck_id;
    status := 'created';
    code := 'OCCLUSION_CARDS_CREATED';
    request_id := v_request_id;
    return next;
  end loop;

  update public.image_occlusion_assets
  set masks = p_boxes, status = 'associated', associated_at = now(), last_request_id = v_request_id
  where id = p_asset_id and user_id = v_user_id;
end;
$$;
revoke execute on function public.create_image_occlusion_note(uuid, jsonb, uuid, uuid, text) from public, anon;
grant execute on function public.create_image_occlusion_note(uuid, jsonb, uuid, uuid, text) to authenticated;

create or replace function public.list_staged_image_occlusion_assets(p_limit integer default 100)
returns table (
  asset_id uuid,
  note_id uuid,
  deck_id uuid,
  storage_bucket text,
  storage_path text,
  mime_type text,
  file_size_bytes bigint,
  status text,
  created_at timestamptz
)
language sql
security invoker
stable
set search_path = public
as $$
  select a.id, a.note_id, a.deck_id, a.storage_bucket, a.storage_path,
         a.mime_type, a.file_size_bytes, a.status, a.created_at
  from public.image_occlusion_assets a
  where a.user_id = auth.uid() and a.status = 'staged'
  order by a.created_at asc
  limit least(greatest(coalesce(p_limit, 100), 1), 1000);
$$;
revoke execute on function public.list_staged_image_occlusion_assets(integer) from public, anon;
grant execute on function public.list_staged_image_occlusion_assets(integer) to authenticated;

comment on table public.image_occlusion_assets is 'Owned staging and association record for image-occlusion media; the asset is not silently discarded when card creation fails.';
comment on function public.create_image_occlusion_note(uuid, jsonb, uuid, uuid, text) is 'F19/F20: atomically validates owned note/deck/asset/masks, creates cards, associates media and returns status/code/request_id.';
comment on function public.media_storage_metadata_allowed(jsonb) is 'F46: server-side MIME and 25 MiB Storage metadata guard for card media.';

grant select,insert,update,delete on public.image_occlusion_assets to authenticated;
