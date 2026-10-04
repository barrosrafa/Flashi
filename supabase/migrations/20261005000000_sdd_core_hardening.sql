-- Flashi SDD core hardening: activation consistency, atomic content writes,
-- quota governance and bounded dashboard aggregation.
begin;

create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated;

create table if not exists public.learning_plans (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  goal text,
  target_date date,
  weekly_minutes integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint learning_plans_weekly_minutes_check check (weekly_minutes is null or weekly_minutes between 15 and 10080),
  unique (user_id)
);
alter table public.learning_plans enable row level security;
drop policy if exists learning_plans_owner_all on public.learning_plans;
create policy learning_plans_owner_all on public.learning_plans
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- The existing activation contract is extended rather than duplicated. The
-- plan and activation FSM transition commit in the same transaction.
drop function if exists public.process_activation(text, text, text);
create or replace function public.process_activation(
  p_idempotency_key text,
  p_fingerprint text,
  p_request_id text default null,
  p_goal text default null,
  p_target_date date default null,
  p_weekly_minutes integer default null
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_existing public.activation_idempotency%rowtype;
  v_response jsonb;
  v_plan_id uuid;
begin
  if v_user_id is null then raise exception 'AUTH_REQUIRED' using errcode = 'P0001'; end if;
  if p_idempotency_key is null or length(trim(p_idempotency_key)) < 8 or length(p_idempotency_key) > 200 then
    raise exception 'INVALID_IDEMPOTENCY_KEY' using errcode = 'P0001';
  end if;
  if p_fingerprint is null or length(p_fingerprint) <> 64 then
    raise exception 'INVALID_FINGERPRINT' using errcode = 'P0001';
  end if;
  if p_goal is not null and length(p_goal) > 500 then raise exception 'INVALID_GOAL' using errcode = 'P0001'; end if;
  if p_weekly_minutes is not null and (p_weekly_minutes < 15 or p_weekly_minutes > 10080) then
    raise exception 'INVALID_WEEKLY_MINUTES' using errcode = 'P0001';
  end if;
  if p_target_date is not null and p_target_date < current_date then raise exception 'INVALID_TARGET_DATE' using errcode = 'P0001'; end if;

  insert into public.activation_flows(user_id, status, errors, last_request_id, updated_at)
  values (v_user_id, 'PENDING', '[]'::jsonb, p_request_id, now())
  on conflict (user_id) do update set updated_at = now(), last_request_id = excluded.last_request_id;
  select * into v_existing from public.activation_idempotency
    where user_id = v_user_id and idempotency_key = p_idempotency_key for update;
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
  on conflict (user_id) do update set goal = excluded.goal, target_date = excluded.target_date,
    weekly_minutes = excluded.weekly_minutes, updated_at = now()
  returning id into v_plan_id;
  update public.activation_flows set status = 'ACTIVE', activated_at = coalesce(activated_at, now()), updated_at = now()
    where user_id = v_user_id;
  v_response := jsonb_build_object('status', 'ACTIVE', 'plan_id', v_plan_id, 'request_id', p_request_id, 'processed_at', now());
  update public.activation_idempotency set status = 'completed', response = v_response, locked_until = null, updated_at = now()
    where user_id = v_user_id and idempotency_key = p_idempotency_key;
  return v_response;
exception when others then
  update public.activation_flows set status = 'FAILED', errors = jsonb_build_array(sqlerrm), last_request_id = p_request_id, updated_at = now()
    where user_id = auth.uid() and sqlstate <> 'P0001';
  raise;
end;
$$;
revoke execute on function public.process_activation(text, text, text, text, date, integer) from public, anon;
grant execute on function public.process_activation(text, text, text, text, date, integer) to authenticated;

create or replace function public.update_note_and_cards(
  p_note_id uuid, p_note_fields jsonb, p_cards jsonb
) returns jsonb language plpgsql security invoker set search_path = '' as $$
declare v_card jsonb;
begin
  update public.notes set fields = p_note_fields, updated_at = now()
    where id = p_note_id and user_id = auth.uid();
  if not found then raise exception 'NOTE_NOT_FOUND' using errcode = 'P0001'; end if;
  for v_card in select value from jsonb_array_elements(coalesce(p_cards, '[]'::jsonb)) loop
    update public.cards set fields = v_card->'fields', updated_at = now()
      where id = (v_card->>'id')::uuid and note_id = p_note_id and user_id = auth.uid();
  end loop;
  return jsonb_build_object('success', true, 'note_id', p_note_id);
end; $$;
revoke execute on function public.update_note_and_cards(uuid, jsonb, jsonb) from public, anon;
grant execute on function public.update_note_and_cards(uuid, jsonb, jsonb) to authenticated;

create or replace function public.consume_user_quota(p_user_id uuid, p_service text, p_cost_units integer)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_quota public.user_quotas%rowtype;
begin
  if (auth.uid() is null or auth.uid() <> p_user_id) and coalesce(auth.jwt()->>'role', '') <> 'service_role' then return false; end if;
  if p_cost_units is null or p_cost_units < 1 then return false; end if;
  select * into v_quota from public.user_quotas where user_id = p_user_id and quota = p_service for update;
  if not found or v_quota.used + p_cost_units > v_quota.limit_value then return false; end if;
  update public.user_quotas set used = used + p_cost_units, updated_at = now()
    where user_id = p_user_id and quota = p_service;
  return true;
end; $$;
revoke execute on function public.consume_user_quota(uuid, text, integer) from public, anon;
grant execute on function public.consume_user_quota(uuid, text, integer) to authenticated, service_role;

create or replace function public.get_deck_summaries()
returns table (deck_id uuid, name text, card_count bigint, due_count bigint)
language sql security invoker set search_path = '' as $$
  select d.id, d.name, count(c.id), count(c.id) filter (where cls.due_at <= now() and not cls.is_suspended)
  from public.decks d left join public.cards c on c.deck_id = d.id and c.deleted_at is null
  left join public.card_learning_state cls on cls.card_id = c.id and cls.user_id = auth.uid()
  where d.user_id = auth.uid() and d.deleted_at is null group by d.id, d.name order by d.name;
$$;
revoke execute on function public.get_deck_summaries() from public, anon;
grant execute on function public.get_deck_summaries() to authenticated;

commit;
