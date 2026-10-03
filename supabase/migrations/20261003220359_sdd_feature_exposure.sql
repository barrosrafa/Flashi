-- Flashi SDD: all user-facing capabilities are enabled and observable.
-- The leaderboard is intentionally readable by authenticated users, while writes
-- remain owned by the security-definer XP RPC.
begin;

grant select on public.leaderboard_entries to authenticated;
revoke insert, update, delete, truncate, references, trigger on public.leaderboard_entries from public, anon, authenticated;

create or replace function public.refresh_leaderboard_entries()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;
  refresh materialized view concurrently public.leaderboard_entries;
end;
$$;

revoke all on function public.refresh_leaderboard_entries() from public, anon;
grant execute on function public.refresh_leaderboard_entries() to authenticated;

comment on function public.refresh_leaderboard_entries() is
  'Refreshes the leaderboard projection for an authenticated request; XP writes remain idempotent in sync_session_xp.';
comment on table public.deck_import_jobs is
  'Authenticated import batches; file parsing and materialization are transactional and auditable.';

commit;
