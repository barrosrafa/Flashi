create or replace function public.sync_session_xp_confirmed(p_session_id uuid,p_expected_review_count integer)
returns table(session_id uuid,review_count integer,xp_awarded integer,xp_total integer,level_current integer)
language plpgsql security definer set search_path=public as $$
declare owner_id uuid := auth.uid(); streak_count integer; streak_anchor date; actual_count integer; computed_xp integer; delta_xp integer; profile_row public.user_gamification_profiles%rowtype; existing_row public.gamification_xp_sessions%rowtype;
begin
  if owner_id is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_session_id is null or p_expected_review_count is null or p_expected_review_count<1 then raise exception 'SESSION_REVIEW_COUNT_INVALID'; end if;
  insert into public.user_gamification_profiles(user_id) values(owner_id) on conflict do nothing;
  select g.* into profile_row from public.user_gamification_profiles g where g.user_id=owner_id for update;
  insert into public.user_badges(user_id,badge_id) select owner_id,b.id from public.badges_definition b where b.xp_requirement<=profile_row.xp_total on conflict(user_id,badge_id) do nothing;
  select count(*)::integer into actual_count from public.review_logs r where r.user_id=owner_id and r.session_id=p_session_id;
  if actual_count<>p_expected_review_count then raise exception 'SESSION_REVIEWS_PENDING'; end if;
  select coalesce(sum(case r.rating when 'again' then 1 when 'hard' then 3 when 'good' then 5 when 'easy' then 7 end),0)::integer into computed_xp from public.review_logs r where r.user_id=owner_id and r.session_id=p_session_id;
  streak_anchor:=case when exists(select 1 from public.daily_statistics d where d.user_id=owner_id and d.stat_date=current_date and d.reviews_count>0) then current_date else current_date-1 end;
  select count(*)::integer into streak_count from (select d.stat_date,row_number() over(order by d.stat_date desc) rn from public.daily_statistics d where d.user_id=owner_id and d.stat_date<=streak_anchor and d.reviews_count>0 order by d.stat_date desc limit 3660) days where stat_date=streak_anchor-(rn-1)::integer;
  update public.user_gamification_profiles set streak_days_count=streak_count,highest_streak_count=greatest(highest_streak_count,streak_count) where user_id=owner_id returning * into profile_row;
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
  on conflict on constraint gamification_xp_sessions_pkey do update set xp_awarded=excluded.xp_awarded,review_count=excluded.review_count;
  return query select p_session_id,actual_count,computed_xp,profile_row.xp_total,profile_row.level_current;
end $$;
revoke all on function public.sync_session_xp_confirmed(uuid,integer) from public,anon;
grant execute on function public.sync_session_xp_confirmed(uuid,integer) to authenticated;


alter table public.gamification_xp_sessions enable row level security;
drop policy if exists confirmed_xp_sessions_owner_read on public.gamification_xp_sessions;
create policy confirmed_xp_sessions_owner_read on public.gamification_xp_sessions for select to authenticated using(user_id=auth.uid());
grant select on public.gamification_xp_sessions to authenticated;

create or replace function public.job_claim_heartbeat() returns trigger language plpgsql set search_path=public as $$
begin
 if old.status::text='cancelled' and new.status::text not in ('queued','cancelled') then raise exception 'JOB_CANCELLED'; end if;
 if new.status::text in ('processing','running') and old.status::text='queued' and old.status is distinct from new.status then new.attempt_count:=old.attempt_count+1;new.heartbeat_at:=now();end if;
 return new;
end $$;
