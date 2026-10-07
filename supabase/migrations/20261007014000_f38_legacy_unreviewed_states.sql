-- Initialize only never-reviewed legacy cards; do not reset any learning state or review history.
create or replace function public.initialize_unreviewed_card_states(p_deck_id uuid default null,p_limit integer default 1000)
returns integer language plpgsql security invoker set search_path=public as $$
declare affected integer;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED';end if;
 with recursive targets as (
  select d.id from public.decks d where d.user_id=auth.uid() and (p_deck_id is null or d.id=p_deck_id)
  union select d.id from public.decks d join targets t on d.parent_deck_id=t.id where d.user_id=auth.uid()
 ) insert into public.card_learning_state(user_id,card_id,state)
 select auth.uid(),c.id,'new' from public.cards c where c.user_id=auth.uid() and c.deleted_at is null and not c.is_archived and public.deck_is_active(c.deck_id)
 and c.deck_id in(select id from targets) and not exists(select 1 from public.card_learning_state ls where ls.user_id=auth.uid() and ls.card_id=c.id)
 and not exists(select 1 from public.review_logs r where r.user_id=auth.uid() and r.card_id=c.id)
 order by c.created_at,c.id limit least(greatest(p_limit,1),1000) on conflict(user_id,card_id) do nothing;
 get diagnostics affected=row_count;return affected;
end $$;
revoke all on function public.initialize_unreviewed_card_states(uuid,integer) from public,anon;
grant execute on function public.initialize_unreviewed_card_states(uuid,integer) to authenticated;
