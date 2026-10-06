-- SDD P0: every new user starts with a coherent product state.
-- Provisioning is idempotent so it can safely repair users created before this migration.
begin;

create or replace function public.provision_user_access(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_user_id is null then raise exception 'USER_ID_REQUIRED'; end if;

  insert into public.activation_flows(user_id, status, errors, updated_at)
  values (p_user_id, 'PENDING', '[]'::jsonb, now())
  on conflict (user_id) do nothing;

  insert into public.learning_plans(user_id)
  values (p_user_id)
  on conflict (user_id) do nothing;

  insert into public.user_entitlements(user_id, entitlement, status, source, metadata)
  values
    (p_user_id, 'study', 'active', 'free', jsonb_build_object('plan', 'free')),
    (p_user_id, 'basic_analytics', 'active', 'free', jsonb_build_object('plan', 'free'))
  on conflict (user_id, entitlement) do nothing;

  insert into public.user_quotas(user_id, quota, used, limit_value, reset_at)
  values
    (p_user_id, 'ai_generation', 0, 100, date_trunc('month', now()) + interval '1 month'),
    (p_user_id, 'tts', 0, 50, date_trunc('month', now()) + interval '1 month')
  on conflict (user_id, quota) do nothing;
end;
$$;

revoke execute on function public.provision_user_access(uuid) from public, anon, authenticated;
grant execute on function public.provision_user_access(uuid) to service_role;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, nullif(coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name'), ''))
  on conflict (id) do update set display_name = coalesce(public.profiles.display_name, excluded.display_name);
  insert into public.study_settings (user_id) values (new.id) on conflict (user_id) do nothing;
  perform public.provision_user_access(new.id);
  return new;
end;
$$;

-- Repair accounts created before the trigger was hardened. This is idempotent.
do $$
declare v_user_id uuid;
begin
  for v_user_id in select id from auth.users loop
    perform public.provision_user_access(v_user_id);
  end loop;
end;
$$;

-- Activation also repairs legacy users and keeps plan/access state in one transaction.
create or replace function public.process_activation(
  p_idempotency_key text,
  p_fingerprint text,
  p_request_id text default null,
  p_goal text default null,
  p_target_date date default null,
  p_weekly_minutes integer default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_existing public.activation_idempotency%rowtype;
  v_response jsonb;
  v_plan_id uuid;
begin
  if v_user_id is null then raise exception 'AUTH_REQUIRED' using errcode = 'P0001'; end if;
  if p_idempotency_key is null or length(trim(p_idempotency_key)) < 8 or length(p_idempotency_key) > 200 then raise exception 'INVALID_IDEMPOTENCY_KEY' using errcode = 'P0001'; end if;
  if p_fingerprint is null or length(p_fingerprint) <> 64 then raise exception 'INVALID_FINGERPRINT' using errcode = 'P0001'; end if;
  if p_goal is not null and length(p_goal) > 500 then raise exception 'INVALID_GOAL' using errcode = 'P0001'; end if;
  if p_weekly_minutes is not null and (p_weekly_minutes < 15 or p_weekly_minutes > 10080) then raise exception 'INVALID_WEEKLY_MINUTES' using errcode = 'P0001'; end if;
  if p_target_date is not null and p_target_date < current_date then raise exception 'INVALID_TARGET_DATE' using errcode = 'P0001'; end if;

  perform public.provision_user_access(v_user_id);
  insert into public.activation_flows(user_id, status, errors, last_request_id, updated_at)
  values (v_user_id, 'PENDING', '[]'::jsonb, p_request_id, now())
  on conflict (user_id) do update set updated_at = now(), last_request_id = excluded.last_request_id;

  select * into v_existing from public.activation_idempotency where user_id = v_user_id and idempotency_key = p_idempotency_key for update;
  if found then
    if v_existing.fingerprint <> p_fingerprint then raise exception 'IDEMPOTENCY_KEY_REUSED' using errcode = 'P0001'; end if;
    if v_existing.status = 'completed' and v_existing.response is not null then return v_existing.response; end if;
    if v_existing.status = 'processing' and coalesce(v_existing.locked_until, now()) > now() then raise exception 'IDEMPOTENCY_IN_PROGRESS' using errcode = 'P0001'; end if;
  end if;
  insert into public.activation_idempotency(user_id, idempotency_key, fingerprint, status, request_id, locked_until, updated_at)
  values (v_user_id, p_idempotency_key, p_fingerprint, 'processing', p_request_id, now() + interval '60 seconds', now())
  on conflict (user_id, idempotency_key) do update set status = 'processing', request_id = excluded.request_id, locked_until = excluded.locked_until, updated_at = now();

  insert into public.learning_plans(user_id, goal, target_date, weekly_minutes)
  values (v_user_id, p_goal, p_target_date, p_weekly_minutes)
  on conflict (user_id) do update set goal = excluded.goal, target_date = excluded.target_date, weekly_minutes = excluded.weekly_minutes, updated_at = now()
  returning id into v_plan_id;
  update public.activation_flows set status = 'ACTIVE', activated_at = coalesce(activated_at, now()), updated_at = now() where user_id = v_user_id;
  v_response := jsonb_build_object('status', 'ACTIVE', 'plan_id', v_plan_id, 'request_id', p_request_id, 'processed_at', now());
  update public.activation_idempotency set status = 'completed', response = v_response, locked_until = null, updated_at = now() where user_id = v_user_id and idempotency_key = p_idempotency_key;
  return v_response;
exception when others then
  update public.activation_flows set status = 'FAILED', errors = jsonb_build_array(sqlerrm), last_request_id = p_request_id, updated_at = now() where user_id = auth.uid() and sqlstate <> 'P0001';
  raise;
end;
$$;

revoke execute on function public.process_activation(text, text, text, text, date, integer) from public, anon;
grant execute on function public.process_activation(text, text, text, text, date, integer) to authenticated;

commit;
begin;

create or replace function public.restore_deck(p_deck_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_deleted_at timestamptz;
  v_decks integer := 0;
  v_cards integer := 0;
begin
  select deleted_at into v_deleted_at
    from public.decks
    where id = p_deck_id and user_id = auth.uid() and deleted_at is not null
    for update;
  if v_deleted_at is null then
    raise exception 'DECK_NOT_FOUND_OR_NOT_DELETED' using errcode = 'P0001';
  end if;
  update public.decks
    set deleted_at = null, is_archived = false, updated_at = now()
    where id = p_deck_id and user_id = auth.uid() and deleted_at = v_deleted_at;
  get diagnostics v_decks = row_count;
  update public.decks
    set deleted_at = null, is_archived = false, updated_at = now()
    where parent_deck_id = p_deck_id and user_id = auth.uid() and deleted_at = v_deleted_at;
  get diagnostics v_decks = v_decks + row_count;
  update public.cards
    set deleted_at = null, updated_at = now()
    where deck_id = p_deck_id and user_id = auth.uid() and deleted_at = v_deleted_at;
  get diagnostics v_cards = row_count;
  return jsonb_build_object('deck_count', v_decks, 'card_count', v_cards);
end;
$$;
revoke execute on function public.restore_deck(uuid) from public, anon;
grant execute on function public.restore_deck(uuid) to authenticated;

commit;
