-- Keep the deployed snapshot reproducible and close contract gaps found in the parity audit.

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
  return new;
end;
$$;

-- The final snapshot must expose every user-owned entity that already has a
-- USN/grave contract; this is additive and does not invent new entities.
create or replace function public.get_incremental_sync(
  p_after_usn bigint default 0,
  p_limit integer default 500
)
returns table (entity_type text, entity_key text, usn bigint, is_deleted boolean, payload jsonb)
language sql
security invoker
stable
set search_path = public
as $$
  with changes (entity_type, entity_key, usn, is_deleted, payload) as (
    select 'deck', d.id::text, d.usn, false, to_jsonb(d) from public.decks d where d.user_id = auth.uid() and d.deleted_at is null and d.usn > p_after_usn
    union all select 'note', n.id::text, n.usn, false, to_jsonb(n) from public.notes n where n.user_id = auth.uid() and n.deleted_at is null and n.usn > p_after_usn
    union all select 'card', c.id::text, c.usn, false, to_jsonb(c) from public.cards c where c.user_id = auth.uid() and c.deleted_at is null and c.usn > p_after_usn
    union all select 'card_media', m.id::text, m.usn, false, to_jsonb(m) from public.card_media m where m.user_id = auth.uid() and m.usn > p_after_usn
    union all select 'card_learning_state', s.id::text, s.usn, false, to_jsonb(s) from public.card_learning_state s where s.user_id = auth.uid() and s.usn > p_after_usn
    union all select 'review_log', r.id::text, r.usn, false, to_jsonb(r) from public.review_logs r where r.user_id = auth.uid() and r.usn > p_after_usn
    union all select 'tag', t.id::text, t.usn, false, to_jsonb(t) from public.tags t where t.user_id = auth.uid() and t.usn > p_after_usn
    union all select 'card_template', t.id::text, t.usn, false, to_jsonb(t) from public.card_templates t where t.user_id = auth.uid() and t.usn > p_after_usn
    union all select 'study_settings', s.user_id::text, s.usn, false, to_jsonb(s) from public.study_settings s where s.user_id = auth.uid() and s.usn > p_after_usn
    union all select 'user_deck_settings', s.user_id::text || ':' || s.deck_id::text, s.usn, false, to_jsonb(s) from public.user_deck_settings s where s.user_id = auth.uid() and s.usn > p_after_usn
    union all select 'daily_statistics', s.user_id::text || ':' || s.stat_date::text, s.usn, false, to_jsonb(s) from public.daily_statistics s where s.user_id = auth.uid() and s.usn > p_after_usn
    union all select 'note_card_definition', d.id::text, d.usn, false, to_jsonb(d) from public.note_card_definitions d where d.usn > p_after_usn
    union all select 'note_cloze_deletion', d.id::text, d.usn, false, to_jsonb(d) from public.note_cloze_deletions d where d.usn > p_after_usn
    union all select 'fsrs_optimization_run', o.id::text, o.usn, false, to_jsonb(o) from public.fsrs_optimization_runs o where o.user_id = auth.uid() and o.usn > p_after_usn
    union all select 'ai_ingestion_job', j.id::text, j.usn, false, to_jsonb(j) from public.ai_ingestion_jobs j where j.user_id = auth.uid() and j.deleted_at is null and j.usn > p_after_usn
    union all select 'note_image_occlusion_box', b.id::text, b.usn, false, to_jsonb(b) from public.note_image_occlusion_boxes b join public.notes n on n.id = b.note_id where n.user_id = auth.uid() and b.usn > p_after_usn
    union all select 'note_reference', r.id::text, r.usn, false, to_jsonb(r) from public.note_references r join public.notes n on n.id = r.source_note_id where n.user_id = auth.uid() and r.usn > p_after_usn
    union all select 'user_gamification_profile', g.user_id::text, g.usn, false, to_jsonb(g) from public.user_gamification_profiles g where g.user_id = auth.uid() and g.usn > p_after_usn
    union all select 'user_badge', b.id::text, b.usn, false, to_jsonb(b) from public.user_badges b where b.user_id = auth.uid() and b.usn > p_after_usn
    union all select 'deck_exam', e.id::text, e.usn, false, to_jsonb(e) from public.deck_exams e where e.user_id = auth.uid() and e.usn > p_after_usn
    union all select 'socratic_remediation_session', s.id::text, s.usn, false, to_jsonb(s) from public.socratic_remediation_sessions s where s.user_id = auth.uid() and s.usn > p_after_usn
    union all select g.entity_type, g.entity_key, g.usn, true, jsonb_build_object('entity_type', g.entity_type, 'entity_key', g.entity_key, 'deleted_at', g.deleted_at) from public.graves g where g.user_id = auth.uid() and g.usn > p_after_usn
  )
  select * from changes order by usn asc limit least(greatest(coalesce(p_limit, 500), 1), 5000);
$$;

grant execute on function public.claim_ai_ingestion_job() to service_role;
grant execute on function public.materialize_ai_ingestion_batch(uuid, uuid, uuid, jsonb) to service_role;
grant execute on function public.sync_session_xp(uuid) to authenticated;

-- Badges are awarded by backend logic, never by a browser client.
revoke insert, update, delete on table public.user_badges from authenticated;
