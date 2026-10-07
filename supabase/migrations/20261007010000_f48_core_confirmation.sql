-- F02/F03/F04/F35/F39/F47: additive, ownership-preserving core hardening.
-- Existing content/history is not deleted. RLS remains enabled.
create or replace function public.deck_is_active(p_deck_id uuid) returns boolean language sql stable security invoker set search_path=public as $$
 with recursive ancestry as (
  select d.id,d.parent_deck_id,d.deleted_at,d.is_archived,array[d.id] path,false cycle from public.decks d where d.id=p_deck_id
  union all select d.id,d.parent_deck_id,d.deleted_at,d.is_archived,a.path||d.id,d.id=any(a.path) from public.decks d join ancestry a on d.id=a.parent_deck_id where not a.cycle
 ) select coalesce(bool_and(deleted_at is null and not is_archived and not cycle),false) from ancestry;
$$;
revoke all on function public.deck_is_active(uuid) from public,anon;
grant execute on function public.deck_is_active(uuid) to authenticated;

do $$
declare definition text;
begin
  select pg_get_functiondef(p.oid) into definition from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='record_review_fsrs6_idempotent' limit 1;
  if definition is null then raise exception 'REVIEW_RPC_MISSING'; end if;
  definition := regexp_replace(definition, '  if p_expected_usn is not null and v_prev.usn <> p_expected_usn then\s+raise exception ''CARD_STATE_CHANGED'';\s+end if;', '', 'g');
  definition := replace(definition, '  insert into public.review_logs (', E'  if p_expected_usn is not null and v_prev.usn <> p_expected_usn then\n    raise exception ''CARD_STATE_CHANGED'';\n  end if;\n  insert into public.review_logs (');
  execute definition;
end $$;

do $$
declare definition text; function_name text;
begin
  foreach function_name in array array['get_due_cards','get_due_cards_with_exam_schedule','mcp_search_notes','search_notes_by_embedding'] loop
    select pg_get_functiondef(p.oid) into definition from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname=function_name limit 1;
    if definition is null then raise exception 'QUEUE_SEARCH_RPC_MISSING: %', function_name; end if;
    if function_name in ('get_due_cards','get_due_cards_with_exam_schedule') then
      definition := replace(definition, 'and c.deleted_at is null', 'and c.deleted_at is null and public.deck_is_active(c.deck_id) and c.is_archived = false and exists (select 1 from public.decks active_deck where active_deck.id=c.deck_id and active_deck.deleted_at is null and active_deck.is_archived=false)');
    else
      definition := replace(definition, 'and n.deleted_at is null', 'and n.deleted_at is null and public.deck_is_active(n.deck_id) and exists (select 1 from public.decks active_deck where active_deck.id=n.deck_id and active_deck.deleted_at is null and active_deck.is_archived=false)');
    end if;
    execute definition;
  end loop;
end $$;

create or replace function public.soft_delete_deck(p_deck_id uuid)
returns void language plpgsql security invoker set search_path=public as $$
declare owner_id uuid := auth.uid(); deletion_time timestamptz; previous_deleted timestamptz;
begin
  select deleted_at into previous_deleted from public.decks where id=p_deck_id and user_id=owner_id for update;
  if not found then raise exception 'DECK_NOT_FOUND'; end if;
  if previous_deleted is not null then return; end if;
  deletion_time := clock_timestamp();
  with recursive subtree as (
    select id from public.decks where id=p_deck_id and user_id=owner_id
    union all select d.id from public.decks d join subtree s on d.parent_deck_id=s.id where d.user_id=owner_id
  ) update public.decks set deleted_at=deletion_time where id in (select id from subtree) and deleted_at is null;
  with recursive subtree as (
    select id from public.decks where id=p_deck_id and user_id=owner_id
    union all select d.id from public.decks d join subtree s on d.parent_deck_id=s.id where d.user_id=owner_id
  ) update public.cards set deleted_at=deletion_time where deck_id in (select id from subtree) and user_id=owner_id and deleted_at is null;
end $$;

create or replace function public.restore_deck(p_deck_id uuid)
returns jsonb language plpgsql security invoker set search_path=public as $$
declare owner_id uuid:=auth.uid(); deletion_time timestamptz; deck_count integer; card_count integer;
begin
 select deleted_at into deletion_time from public.decks where id=p_deck_id and user_id=owner_id for update;
 if not found then raise exception 'DECK_NOT_FOUND'; end if;
 if deletion_time is null then
  update public.decks set is_archived=false where id=p_deck_id and user_id=owner_id;
  return jsonb_build_object('deck_count',1,'card_count',0);
 end if;
 with recursive subtree as (
  select id from public.decks where id=p_deck_id and user_id=owner_id
  union all select d.id from public.decks d join subtree s on d.parent_deck_id=s.id where d.user_id=owner_id
 ) update public.decks set deleted_at=null,is_archived=case when id=p_deck_id then false else is_archived end where id in(select id from subtree) and deleted_at=deletion_time;
 get diagnostics deck_count=row_count;
 with recursive subtree as (
  select id from public.decks where id=p_deck_id and user_id=owner_id
  union all select d.id from public.decks d join subtree s on d.parent_deck_id=s.id where d.user_id=owner_id
 ) update public.cards set deleted_at=null where deck_id in(select id from subtree) and user_id=owner_id and deleted_at=deletion_time;
 get diagnostics card_count=row_count;
 return jsonb_build_object('deck_count',deck_count,'card_count',card_count);
end $$;

create or replace function public.update_note_and_cards_v2(
  p_note_id uuid, p_note_fields jsonb, p_cards jsonb,
  p_template_id uuid default null, p_update_template boolean default false
) returns jsonb language plpgsql security invoker set search_path=public as $$
declare item jsonb; owner_id uuid := auth.uid();
begin
  if owner_id is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_note_fields is not null and jsonb_typeof(p_note_fields)<>'object' then raise exception 'NOTE_FIELDS_INVALID'; end if;
  if jsonb_typeof(coalesce(p_cards,'[]'::jsonb))<>'array' then raise exception 'NOTE_CARDS_INVALID'; end if;
  perform 1 from public.notes where id=p_note_id and user_id=owner_id and deleted_at is null for update;
  if not found then raise exception 'NOTE_NOT_FOUND'; end if;
  if p_update_template and p_template_id is not null and not exists(select 1 from public.card_templates where id=p_template_id and (user_id=owner_id or is_system)) then raise exception 'TEMPLATE_NOT_ACCESSIBLE'; end if;
  update public.notes set fields=coalesce(p_note_fields,fields), template_id=case when p_update_template then p_template_id else template_id end, updated_at=now() where id=p_note_id and user_id=owner_id;
  for item in select value from jsonb_array_elements(coalesce(p_cards,'[]'::jsonb)) loop
    update public.cards set fields=item->'fields',template_id=case when p_update_template then p_template_id else template_id end,updated_at=now()
    where id=(item->>'id')::uuid and note_id=p_note_id and user_id=owner_id and deleted_at is null;
    if not found then raise exception 'NOTE_CARD_NOT_OWNED'; end if;
  end loop;
  return jsonb_build_object('success',true,'note_id',p_note_id);
end $$;
revoke all on function public.update_note_and_cards_v2(uuid,jsonb,jsonb,uuid,boolean) from public,anon;
grant execute on function public.update_note_and_cards_v2(uuid,jsonb,jsonb,uuid,boolean) to authenticated;

create or replace function public.sync_session_xp_confirmed(p_session_id uuid,p_expected_review_count integer)
returns table(session_id uuid,review_count integer,xp_awarded integer,xp_total integer,level_current integer)
language plpgsql security definer set search_path=public as $$
declare owner_id uuid := auth.uid(); actual_count integer; computed_xp integer; delta_xp integer; profile_row public.user_gamification_profiles%rowtype; existing_row public.gamification_xp_sessions%rowtype;
begin
  if owner_id is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_session_id is null or p_expected_review_count is null or p_expected_review_count<1 then raise exception 'SESSION_REVIEW_COUNT_INVALID'; end if;
  insert into public.user_gamification_profiles(user_id) values(owner_id) on conflict do nothing;
  select g.* into profile_row from public.user_gamification_profiles g where g.user_id=owner_id for update;
  insert into public.user_badges(user_id,badge_id) select owner_id,b.id from public.badges_definition b where b.xp_requirement<=profile_row.xp_total on conflict(user_id,badge_id) do nothing;
  select count(*)::integer into actual_count from public.review_logs r where r.user_id=owner_id and r.session_id=p_session_id;
  if actual_count<>p_expected_review_count then raise exception 'SESSION_REVIEWS_PENDING'; end if;
  select coalesce(sum(case r.rating when 'again' then 1 when 'hard' then 3 when 'good' then 5 when 'easy' then 7 end),0)::integer into computed_xp from public.review_logs r where r.user_id=owner_id and r.session_id=p_session_id;
  computed_xp := greatest(1,round(computed_xp*(1+least(coalesce(profile_row.streak_days_count,0)*0.01,0.5)))::integer);
  select x.* into existing_row from public.gamification_xp_sessions x where x.user_id=owner_id and x.session_id=p_session_id for update;
  if found then
    -- Existing confirmed sessions keep the original award; legacy partial awards are reconciled once.
    if existing_row.review_count=actual_count then
      return query select p_session_id,actual_count,existing_row.xp_awarded,profile_row.xp_total,profile_row.level_current; return;
    end if;
    delta_xp := greatest(0,computed_xp-existing_row.xp_awarded);
  else delta_xp := computed_xp; end if;
  update public.user_gamification_profiles g set xp_total=g.xp_total+delta_xp,level_current=greatest(1,floor(sqrt((g.xp_total+delta_xp)::numeric/100))::integer+1),updated_at=now() where g.user_id=owner_id returning g.* into profile_row;
  insert into public.user_badges(user_id,badge_id) select owner_id,b.id from public.badges_definition b where b.xp_requirement<=profile_row.xp_total on conflict(user_id,badge_id) do nothing;
  insert into public.gamification_xp_sessions(user_id,session_id,xp_awarded,review_count) values(owner_id,p_session_id,computed_xp,actual_count)
  on conflict(user_id,session_id) do update set xp_awarded=excluded.xp_awarded,review_count=excluded.review_count;
  return query select p_session_id,actual_count,computed_xp,profile_row.xp_total,profile_row.level_current;
end $$;
revoke all on function public.sync_session_xp_confirmed(uuid,integer) from public,anon;
grant execute on function public.sync_session_xp_confirmed(uuid,integer) to authenticated;

create or replace function public.list_deck_cards_page(p_deck_id uuid,p_query text default '',p_cursor_time timestamptz default null,p_cursor_id uuid default null,p_limit integer default 101)
returns setof public.cards language sql stable security invoker set search_path=public as $$
 select c.* from public.cards c join public.decks d on d.id=c.deck_id
 where c.deck_id=p_deck_id and c.deleted_at is null and not c.is_archived and d.deleted_at is null and not d.is_archived and public.deck_is_active(d.id)
 and (coalesce(p_query,'')='' or position(lower(p_query) in lower(c.fields::text))>0)
 and (p_cursor_time is null or c.created_at<p_cursor_time or (c.created_at=p_cursor_time and c.id<p_cursor_id))
 order by c.created_at desc,c.id desc limit least(greatest(p_limit,1),101);
$$;
create or replace function public.list_deck_notes_page(p_deck_id uuid,p_query text default '',p_cursor_time timestamptz default null,p_cursor_id uuid default null,p_limit integer default 101)
returns setof public.notes language sql stable security invoker set search_path=public as $$
 select n.* from public.notes n join public.decks d on d.id=n.deck_id
 where n.deck_id=p_deck_id and n.deleted_at is null and d.deleted_at is null and not d.is_archived and public.deck_is_active(d.id)
 and (coalesce(p_query,'')='' or position(lower(p_query) in lower(n.fields::text))>0)
 and (p_cursor_time is null or n.updated_at<p_cursor_time or (n.updated_at=p_cursor_time and n.id<p_cursor_id))
 order by n.updated_at desc,n.id desc limit least(greatest(p_limit,1),101);
$$;
revoke all on function public.list_deck_cards_page(uuid,text,timestamptz,uuid,integer) from public,anon;
revoke all on function public.list_deck_notes_page(uuid,text,timestamptz,uuid,integer) from public,anon;
grant execute on function public.list_deck_cards_page(uuid,text,timestamptz,uuid,integer),public.list_deck_notes_page(uuid,text,timestamptz,uuid,integer) to authenticated;

create schema if not exists private;
create table if not exists private.observability_runtime_config(singleton boolean primary key default true check(singleton),sentry_dsn text,posthog_token text,posthog_host text default 'https://us.i.posthog.com');
revoke all on private.observability_runtime_config from public,anon,authenticated;
create or replace function public.read_observability_runtime_config()
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('sentry_dsn',sentry_dsn,'posthog_token',posthog_token,'posthog_host',posthog_host) from private.observability_runtime_config where singleton and auth.role()='service_role' limit 1;
$$;
revoke all on function public.read_observability_runtime_config() from public,anon,authenticated;
grant execute on function public.read_observability_runtime_config() to service_role;

-- F39: rankings use the same confirmed XP source, not an unrefreshed projection.
create or replace function public.list_leaderboard_entries(p_limit integer default 50)
returns setof public.leaderboard_entries language sql security definer set search_path=public as $$
 select row_number() over(order by g.xp_total desc,g.user_id),g.user_id,p.display_name,g.xp_total,g.level_current,g.updated_at
 from public.user_gamification_profiles g left join public.profiles p on p.id=g.user_id
 where auth.uid() is not null order by g.xp_total desc,g.user_id limit least(greatest(coalesce(p_limit,50),1),100);
$$;
