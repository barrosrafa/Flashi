-- Flashi SDD hardening: expose leaderboard through a bounded RPC instead of
-- making the materialized view directly selectable through PostgREST.
begin;

create index if not exists idx_deck_import_jobs_deck on public.deck_import_jobs(deck_id);
create index if not exists idx_user_badges_badge on public.user_badges(badge_id);

create or replace function public.list_leaderboard_entries(p_limit integer default 50)
returns setof public.leaderboard_entries
language sql
security definer
set search_path = public
as $$
  select *
  from public.leaderboard_entries
  order by rank asc
  limit least(greatest(coalesce(p_limit, 50), 1), 100);
$$;

revoke all on function public.list_leaderboard_entries(integer) from public, anon;
grant execute on function public.list_leaderboard_entries(integer) to authenticated;
revoke select on public.leaderboard_entries from public, anon, authenticated;

comment on function public.list_leaderboard_entries(integer) is
  'Bounded authenticated leaderboard read; the underlying materialized view is not exposed directly via PostgREST.';

commit;
