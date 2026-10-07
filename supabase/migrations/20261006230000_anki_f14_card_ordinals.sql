-- F14: preserve the source card ordinal and rendered/card fields at the
-- note/card boundary. The APKG reader is the authority for which cards exist;
-- this RPC must not renumber sparse ordinals or synthesize cards.
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
  v_card_fields jsonb;
  v_template_id uuid;
  v_ordinal integer := 0;
  v_card_ordinal integer;
  v_card_count integer := 0;
  v_ordinals integer[] := '{}'::integer[];
  v_kind text;
  v_cloze_ordinal integer;
  v_front text;
  v_back text;
begin
  if v_user_id is null then
    raise exception 'Authentication is required';
  end if;
  if p_fields is null or p_fields = '{}'::jsonb or jsonb_typeof(p_fields) <> 'object' then
    raise exception 'p_fields must be a non-empty JSON object';
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
        'card_ordinal', 0,
        'card_kind', 'basic',
        'front', coalesce(p_fields ->> 'Front', ''),
        'back', coalesce(p_fields ->> 'Back', ''),
        'fields', p_fields
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

  if p_source='native' and p_external_id is not null then
    perform pg_advisory_xact_lock(hashtextextended(v_user_id::text||':'||p_external_id,0));
    select n.id into v_note_id from public.notes n where n.user_id=v_user_id and n.source_format='native' and n.external_id=p_external_id and n.deleted_at is null;
    if v_note_id is not null then
      if not exists(select 1 from public.notes n where n.id=v_note_id and n.fields=p_fields and n.deck_id=p_deck_id and n.template_id is not distinct from p_template_id) then raise exception 'IDEMPOTENCY_KEY_REUSED'; end if;
      return query select v_note_id,array(select c.id from public.cards c where c.note_id=v_note_id and c.deleted_at is null order by c.card_ordinal); return;
    end if;
  end if;
  insert into public.notes (
    user_id, deck_id, template_id, fields, source_format, source,
    external_id, content_hash
  ) values (
    v_user_id, p_deck_id, v_template_id, p_fields,
    case when p_source='native' then 'native' when p_source = 'mcp' then 'mcp' else 'api' end,
    p_source, p_external_id, p_content_hash
  ) returning id into v_note_id;

  for v_definition in select value from jsonb_array_elements(p_card_definitions)
  loop
    v_kind := coalesce(v_definition ->> 'card_kind', 'basic');
    if v_kind not in ('basic', 'reverse', 'cloze') then
      raise exception 'Invalid card_kind: %', v_kind;
    end if;
    v_cloze_ordinal := nullif(v_definition ->> 'cloze_ordinal', '')::integer;
    if v_kind = 'cloze' and (v_cloze_ordinal is null or v_cloze_ordinal <= 0) then
      raise exception 'Cloze card definitions require a positive cloze_ordinal';
    end if;
    if v_kind <> 'cloze' and v_cloze_ordinal is not null then
      raise exception 'Only Cloze cards may have cloze_ordinal';
    end if;

    v_card_ordinal := nullif(v_definition ->> 'card_ordinal', '')::integer;
    if v_card_ordinal is null then v_card_ordinal := v_ordinal; end if;
    if v_card_ordinal < 0 or v_card_ordinal = any(v_ordinals) then
      raise exception 'card_ordinal must be unique and non-negative within each note';
    end if;
    v_ordinals := array_append(v_ordinals, v_card_ordinal);
    v_ordinal := greatest(v_ordinal, v_card_ordinal + 1);

    v_front := coalesce(v_definition ->> 'front', '');
    v_back := coalesce(v_definition ->> 'back', '');
    v_card_fields := case
      when jsonb_typeof(v_definition -> 'fields') = 'object' then v_definition -> 'fields'
      else jsonb_build_object('Front', v_front, 'Back', v_back)
    end;
    v_card_fields:=v_card_fields||jsonb_build_object('__flashi_rendered_front',v_front,'__flashi_rendered_back',v_back);
    if v_card_fields = '{}'::jsonb or (v_front = '' and v_back = '') then
      raise exception 'Each card definition must include front or back and non-empty fields';
    end if;

    insert into public.cards (
      user_id, deck_id, template_id, note_group_id, note_id,
      card_ordinal, card_kind, cloze_ordinal, fields
    ) values (
      v_user_id, p_deck_id, v_template_id, v_note_id, v_note_id,
      v_card_ordinal, v_kind, v_cloze_ordinal, v_card_fields
    ) returning id into v_card_id;

    insert into public.card_learning_state (user_id, card_id)
    values (v_user_id, v_card_id)
    on conflict (user_id, card_id) do nothing;

    v_card_ids := array_append(coalesce(v_card_ids, '{}'::uuid[]), v_card_id);
    v_card_count := v_card_count + 1;
  end loop;

  insert into public.mcp_tool_audit (
    user_id, tool_name, request_id, result_count
  ) values (
    v_user_id, 'mcp_create_note', p_request_id, v_card_count
  );

  return query select v_note_id, coalesce(v_card_ids, '{}'::uuid[]);
end;
$$;

comment on function public.mcp_create_note(uuid, jsonb, uuid, jsonb, text, text, text, text) is
  'Atomic note/card creation. F14 preserves caller-supplied card_ordinal and card fields; callers must pass only cards present in the source package.';
