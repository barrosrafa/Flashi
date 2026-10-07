-- Flashi SDD mission hardening: activation FSM, idempotency, entitlements and quotas.
begin;

do $$ begin
  create type public.activation_status as enum ('PENDING', 'VALIDATING', 'ACTIVE', 'SUSPENDED', 'FAILED');
exception when duplicate_object then null;
end $$;

create table if not exists public.activation_flows (
  user_id uuid primary key references auth.users(id) on delete cascade,
  status public.activation_status not null default 'PENDING',
  errors jsonb not null default '[]'::jsonb,
  last_request_id text,
  activated_at timestamptz,
  updated_at timestamptz not null default now()
);
alter table public.activation_flows enable row level security;
drop policy if exists activation_flows_owner_all on public.activation_flows;
create policy activation_flows_owner_all on public.activation_flows
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

create table if not exists public.activation_idempotency (
  user_id uuid not null references auth.users(id) on delete cascade,
  idempotency_key text not null,
  fingerprint text not null,
  status text not null check (status in ('processing', 'completed', 'failed')),
  response jsonb,
  request_id text,
  locked_until timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, idempotency_key)
);
alter table public.activation_idempotency enable row level security;
drop policy if exists activation_idempotency_owner_select on public.activation_idempotency;
create policy activation_idempotency_owner_select on public.activation_idempotency
  for select using (auth.uid() = user_id);
revoke insert, update, delete on public.activation_idempotency from authenticated, anon, public;

create table if not exists public.user_entitlements (
  user_id uuid not null references auth.users(id) on delete cascade,
  entitlement text not null,
  status text not null default 'active' check (status in ('active', 'suspended', 'expired')),
  source text not null default 'internal',
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  primary key (user_id, entitlement)
);
alter table public.user_entitlements enable row level security;
drop policy if exists user_entitlements_owner_select on public.user_entitlements;
create policy user_entitlements_owner_select on public.user_entitlements
  for select using (auth.uid() = user_id);
revoke insert, update, delete on public.user_entitlements from authenticated, anon, public;

create table if not exists public.user_quotas (
  user_id uuid not null references auth.users(id) on delete cascade,
  quota text not null,
  used bigint not null default 0 check (used >= 0),
  limit_value bigint not null check (limit_value >= 0),
  reset_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (user_id, quota)
);
alter table public.user_quotas enable row level security;
drop policy if exists user_quotas_owner_select on public.user_quotas;
create policy user_quotas_owner_select on public.user_quotas
  for select using (auth.uid() = user_id);
revoke insert, update, delete on public.user_quotas from authenticated, anon, public;

create table if not exists public.user_rate_limits (
  user_id uuid not null references auth.users(id) on delete cascade,
  scope text not null,
  window_started_at timestamptz not null default now(),
  request_count integer not null default 0 check (request_count >= 0),
  primary key (user_id, scope)
);
alter table public.user_rate_limits enable row level security;
revoke all on public.user_rate_limits from public, anon, authenticated;

create or replace function public.process_activation(
  p_idempotency_key text,
  p_fingerprint text,
  p_request_id text default null
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_existing public.activation_idempotency%rowtype;
  v_response jsonb;
begin
  if v_user_id is null then raise exception 'AUTH_REQUIRED' using errcode = 'P0001'; end if;
  if p_idempotency_key is null or length(trim(p_idempotency_key)) < 8 or length(p_idempotency_key) > 200 then
    raise exception 'INVALID_IDEMPOTENCY_KEY' using errcode = 'P0001';
  end if;
  if p_fingerprint is null or length(p_fingerprint) <> 64 then
    raise exception 'INVALID_FINGERPRINT' using errcode = 'P0001';
  end if;

  insert into public.activation_flows(user_id, status, errors, last_request_id, updated_at)
  values (v_user_id, 'PENDING', '[]'::jsonb, p_request_id, now())
  on conflict (user_id) do update set updated_at = now(), last_request_id = excluded.last_request_id;

  select * into v_existing from public.activation_idempotency
    where user_id = v_user_id and idempotency_key = p_idempotency_key for update;

  if found then
    if v_existing.fingerprint <> p_fingerprint then
      raise exception 'IDEMPOTENCY_KEY_REUSED' using errcode = 'P0001';
    end if;
    if v_existing.status = 'completed' and v_existing.response is not null then return v_existing.response; end if;
    if v_existing.status = 'processing' and coalesce(v_existing.locked_until, now()) > now() then
      raise exception 'IDEMPOTENCY_IN_PROGRESS' using errcode = 'P0001';
    end if;
  end if;

  insert into public.activation_idempotency(user_id, idempotency_key, fingerprint, status, request_id, locked_until, updated_at)
  values (v_user_id, p_idempotency_key, p_fingerprint, 'processing', p_request_id, now() + interval '60 seconds', now())
  on conflict (user_id, idempotency_key) do update set status = 'processing', request_id = excluded.request_id, locked_until = excluded.locked_until, updated_at = now();

  update public.activation_flows set status = 'VALIDATING', errors = '[]'::jsonb, last_request_id = p_request_id, updated_at = now()
    where user_id = v_user_id;

  -- Domain validation/provisioning is intentionally transaction-bound. Future providers
  -- must run behind this boundary and may only transition through the same FSM.
  update public.activation_flows set status = 'ACTIVE', activated_at = coalesce(activated_at, now()), updated_at = now()
    where user_id = v_user_id;

  v_response := jsonb_build_object(
    'status', 'ACTIVE',
    'request_id', p_request_id,
    'processed_at', now()
  );
  update public.activation_idempotency set status = 'completed', response = v_response, locked_until = null, updated_at = now()
    where user_id = v_user_id and idempotency_key = p_idempotency_key;
  return v_response;
exception when others then
  update public.activation_flows set status = 'FAILED', errors = jsonb_build_array(sqlerrm), last_request_id = p_request_id, updated_at = now()
    where user_id = auth.uid() and sqlstate <> 'P0001';
  raise;
end;
$$;
revoke execute on function public.process_activation(text, text, text) from public, anon;
grant execute on function public.process_activation(text, text, text) to authenticated;

create or replace function public.consume_user_rate_limit(
  p_function_name text,
  p_limit integer default 30,
  p_window_seconds integer default 60
)
returns table(allowed boolean, retry_after_seconds integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_window timestamptz;
  v_count integer;
begin
  if v_user_id is null then raise exception 'Authentication is required'; end if;
  if p_function_name is null or p_function_name !~ '^[a-z0-9-]+$' then raise exception 'Invalid function name'; end if;
  if p_limit < 1 or p_limit > 10000 or p_window_seconds < 1 or p_window_seconds > 86400 then raise exception 'Invalid rate limit configuration'; end if;
  v_window := to_timestamp(floor(extract(epoch from clock_timestamp()) / p_window_seconds) * p_window_seconds);
  insert into public.user_function_rate_limits(user_id, function_name, window_started_at, request_count)
  values (v_user_id, p_function_name, v_window, 1)
  on conflict (user_id, function_name, window_started_at) do update
    set request_count = public.user_function_rate_limits.request_count + 1
    where public.user_function_rate_limits.request_count < p_limit
  returning request_count into v_count;
  if v_count is not null and v_count <= p_limit then
    return query select true, 0;
  end if;
  return query select false, greatest(1, ceil(extract(epoch from (v_window + make_interval(secs => p_window_seconds) - clock_timestamp())))::integer);
end;
$$;
revoke execute on function public.consume_user_rate_limit(text, integer, integer) from public, anon;
grant execute on function public.consume_user_rate_limit(text, integer, integer) to authenticated;

comment on table public.activation_flows is 'Explicit activation FSM state; billing providers remain outside the core domain.';
comment on table public.activation_idempotency is 'User-scoped idempotent activation responses and request fingerprints.';
comment on table public.user_entitlements is 'Future billing boundary; no payment provider is coupled to this table.';
comment on table public.user_quotas is 'Future quota boundary; authoritative writes remain server-side.';
commit;
