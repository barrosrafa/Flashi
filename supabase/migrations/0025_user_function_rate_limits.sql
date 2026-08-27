-- Flashi 0025: per-user rate limiting for paid-provider Edge Functions.
create table if not exists public.user_function_rate_limits (
  user_id uuid not null references auth.users(id) on delete cascade,
  function_name text not null check (length(function_name) between 1 and 80),
  window_started_at timestamptz not null,
  request_count integer not null default 0 check (request_count >= 0),
  primary key (user_id, function_name, window_started_at)
);

revoke all on table public.user_function_rate_limits from public, anon, authenticated;

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
comment on function public.consume_user_rate_limit(text, integer, integer) is 'Atomically limits authenticated calls per user and function within a fixed time window.';
