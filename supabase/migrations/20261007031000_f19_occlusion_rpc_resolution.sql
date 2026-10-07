-- Resolve table-column/output-variable ambiguity without changing the public RPC signature.
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
#variable_conflict use_column
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

  v_ordinal:=coalesce((select max(existing.card_ordinal)+1 from public.cards existing where existing.note_id=p_note_id and existing.deleted_at is null),0);
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

