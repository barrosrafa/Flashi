-- Flashi 0016: harden public views and internal trigger functions after
-- Supabase security advisor inspection.

-- Make the deck tree obey the querying user's permissions and RLS policies.
alter view public.v_deck_tree set (security_invoker = true);

-- Pin search_path on existing functions that predate the worker hardening.
alter function public.set_updated_at() set search_path = public;
alter function public.prevent_review_log_mutation() set search_path = public;
alter function public.get_due_cards(uuid, integer) set search_path = public;
alter function public.record_review(
  uuid, public.review_rating, integer, public.card_state, numeric,
  timestamptz, numeric, numeric, numeric, public.srs_algorithm, text, uuid
) set search_path = public;
alter function public.get_current_streak() set search_path = public;
alter function public.soft_delete_deck(uuid) set search_path = public;
alter function public.get_fsrs_optimization_status() set search_path = public;
alter function public.enqueue_fsrs_optimization() set search_path = public;

-- These functions are invoked by database triggers, not by the public RPC API.
-- Keep SECURITY DEFINER where required for trigger writes, but remove direct
-- execution from API roles.
revoke execute on function public.assign_sync_usn() from public, anon, authenticated;
revoke execute on function public.record_sync_grave() from public, anon, authenticated;
revoke execute on function public.handle_new_user() from public, anon, authenticated;

-- Some projects may already have this helper from an external migration. If it
-- exists, it is internal and should not be callable through PostgREST.
do $$
begin
  if to_regprocedure('public.rls_auto_enable()') is not null then
    revoke execute on function public.rls_auto_enable() from public, anon, authenticated;
  end if;
end;
$$;
