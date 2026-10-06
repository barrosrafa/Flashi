-- Flashi schema snapshot: 05_workers_storage_realtime.sql
-- Storage, scheduled workers, pg_net and deployment-time integrations.
-- Generated from the v1 baseline; historical sources remain in ../migrations_archive/.
-- Apply strictly in lexical order.


-- ================= SOURCE 0011_storage.sql =================
-- 0011_storage.sql
-- Supabase Storage bucket for card media. Files must be uploaded under
-- {auth.uid()}/... so the RLS policy below can scope access per user.

insert into storage.buckets (id, name, public)
values ('card-media', 'card-media', false)
on conflict (id) do nothing;

drop policy if exists "card_media_storage_owner_select" on storage.objects;
create policy "card_media_storage_owner_select" on storage.objects
  for select using (
    bucket_id = 'card-media'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "card_media_storage_owner_insert" on storage.objects;
create policy "card_media_storage_owner_insert" on storage.objects
  for insert with check (
    bucket_id = 'card-media'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "card_media_storage_owner_delete" on storage.objects;
create policy "card_media_storage_owner_delete" on storage.objects
  for delete using (
    bucket_id = 'card-media'
    and (storage.foldername(name))[1] = auth.uid()::text
  );


-- ================= SOURCE 0018_search_optimizer_anki_contracts.sql =================
-- Flashi 0018: durable contracts for semantic search, FSRS optimization
-- workers and private Anki package transfers.

insert into storage.buckets (id, name, public)
values ('anki-transfers', 'anki-transfers', false)
on conflict (id) do nothing;

drop policy if exists "anki_transfers_owner_select" on storage.objects;
create policy "anki_transfers_owner_select" on storage.objects
  for select using (
    bucket_id = 'anki-transfers'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists "anki_transfers_owner_insert" on storage.objects;
create policy "anki_transfers_owner_insert" on storage.objects
  for insert with check (
    bucket_id = 'anki-transfers'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists "anki_transfers_owner_update" on storage.objects;
create policy "anki_transfers_owner_update" on storage.objects
  for update using (
    bucket_id = 'anki-transfers'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  ) with check (
    bucket_id = 'anki-transfers'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists "anki_transfers_owner_delete" on storage.objects;
create policy "anki_transfers_owner_delete" on storage.objects
  for delete using (
    bucket_id = 'anki-transfers'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create or replace function public.claim_fsrs_optimization_job(
  p_run_id uuid default null
)
returns setof public.fsrs_optimization_runs
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_run_id uuid;
begin
  if v_user_id is null then
    raise exception 'Authentication is required';
  end if;

  if p_run_id is null then
    select id into v_run_id
    from public.fsrs_optimization_runs
    where user_id = v_user_id and status = 'queued'
    order by requested_at asc
    for update skip locked
    limit 1;
  else
    v_run_id := p_run_id;
  end if;

  if v_run_id is null then
    return;
  end if;

  update public.fsrs_optimization_runs
  set status = 'running', started_at = now(), error_message = null
  where id = v_run_id and user_id = v_user_id and status = 'queued';

  return query
    select * from public.fsrs_optimization_runs
    where id = v_run_id and user_id = v_user_id and status = 'running';
end;
$$;

create or replace function public.claim_fsrs_optimization_job_for_worker(
  p_run_id uuid
)
returns setof public.fsrs_optimization_runs
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.fsrs_optimization_runs
  set status = 'running', started_at = now(), error_message = null
  where id = p_run_id and status = 'queued';

  return query
    select * from public.fsrs_optimization_runs
    where id = p_run_id and status = 'running';
end;
$$;

create or replace function public.complete_fsrs_optimization_job(
  p_run_id uuid,
  p_new_weights numeric[],
  p_old_loss numeric default null,
  p_new_loss numeric default null
)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_source_count integer;
begin
  if v_user_id is null then
    raise exception 'Authentication is required';
  end if;
  if p_new_weights is null or cardinality(p_new_weights) <> 21 then
    raise exception 'FSRS-6 optimization must return exactly 21 weights';
  end if;
  if exists (select 1 from unnest(p_new_weights) value where value is null or value <> value) then
    raise exception 'FSRS-6 weights must be finite numbers';
  end if;

  select source_review_count into v_source_count
  from public.fsrs_optimization_runs
  where id = p_run_id and user_id = v_user_id and status = 'running'
  for update;
  if not found then
    raise exception 'Optimization job is not owned by the current user or is not running';
  end if;

  update public.fsrs_optimization_runs
  set status = 'completed', new_weights = p_new_weights,
      old_loss = p_old_loss, new_loss = p_new_loss,
      completed_at = now(), error_message = null
  where id = p_run_id and user_id = v_user_id;

  update public.study_settings
  set fsrs_weights = p_new_weights,
      fsrs_version = 'fsrs-6-optimized',
      fsrs_last_optimized_at = now(),
      updated_at = now()
  where user_id = v_user_id;
end;
$$;

create or replace function public.fail_fsrs_optimization_job(
  p_run_id uuid,
  p_error_message text
)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_user_id uuid := (select auth.uid());
begin
  if v_user_id is null then
    raise exception 'Authentication is required';
  end if;
  update public.fsrs_optimization_runs
  set status = 'failed', error_message = left(coalesce(p_error_message, 'Unknown optimizer error'), 1000),
      completed_at = now()
  where id = p_run_id and user_id = v_user_id and status = 'running';
end;
$$;

revoke execute on function public.claim_fsrs_optimization_job_for_worker(uuid) from public, anon, authenticated;
grant execute on function public.claim_fsrs_optimization_job_for_worker(uuid) to service_role;

create or replace function public.complete_fsrs_optimization_job_for_worker(
  p_run_id uuid,
  p_user_id uuid,
  p_new_weights numeric[],
  p_old_loss numeric default null,
  p_new_loss numeric default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_new_weights is null or cardinality(p_new_weights) <> 21 then
    raise exception 'FSRS-6 optimization must return exactly 21 weights';
  end if;
  if exists (select 1 from unnest(p_new_weights) value where value is null or value <> value) then
    raise exception 'FSRS-6 weights must be finite numbers';
  end if;
  update public.fsrs_optimization_runs
  set status = 'completed', new_weights = p_new_weights,
      old_loss = p_old_loss, new_loss = p_new_loss,
      completed_at = now(), error_message = null
  where id = p_run_id and user_id = p_user_id and status = 'running';
  if not found then
    raise exception 'Optimization job is not running for the requested user';
  end if;
  update public.study_settings
  set fsrs_weights = p_new_weights,
      fsrs_version = 'fsrs-6-optimized',
      fsrs_last_optimized_at = now(),
      updated_at = now()
  where user_id = p_user_id;
end;
$$;

create or replace function public.fail_fsrs_optimization_job_for_worker(
  p_run_id uuid,
  p_user_id uuid,
  p_error_message text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.fsrs_optimization_runs
  set status = 'failed', error_message = left(coalesce(p_error_message, 'Unknown optimizer error'), 1000),
      completed_at = now()
  where id = p_run_id and user_id = p_user_id and status = 'running';
end;
$$;

revoke execute on function public.complete_fsrs_optimization_job_for_worker(uuid, uuid, numeric[], numeric, numeric) from public, anon, authenticated;
revoke execute on function public.fail_fsrs_optimization_job_for_worker(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.complete_fsrs_optimization_job_for_worker(uuid, uuid, numeric[], numeric, numeric) to service_role;
grant execute on function public.fail_fsrs_optimization_job_for_worker(uuid, uuid, text) to service_role;

create or replace function public.create_anki_transfer_job(
  p_direction text,
  p_storage_path text,
  p_file_sha256 text default null,
  p_options jsonb default '{}'::jsonb,
  p_source_deck_id uuid default null,
  p_target_deck_id uuid default null
)
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_job_id uuid;
begin
  if v_user_id is null then
    raise exception 'Authentication is required';
  end if;
  if p_direction not in ('import', 'export') then
    raise exception 'direction must be import or export';
  end if;
  -- Validation without regular expressions: avoids escaping faults and keeps the
  -- exact contract (user_id/(imports|exports)/<file>.apkg, no nested folders).
  if p_storage_path is null
     or lower(right(p_storage_path, 5)) <> '.apkg'
     or array_length(string_to_array(p_storage_path, '/'), 1) <> 3
     or split_part(p_storage_path, '/', 1) <> v_user_id::text
     or split_part(p_storage_path, '/', 2) not in ('imports', 'exports')
     or split_part(p_storage_path, '/', 3) = ''
  then
    raise exception 'storage_path must be user-scoped under imports or exports and end in .apkg';
  end if;
  if p_source_deck_id is not null and not exists (
    select 1 from public.decks where id = p_source_deck_id and user_id = v_user_id and deleted_at is null
  ) then
    raise exception 'source_deck_id is not owned by the current user';
  end if;
  if p_target_deck_id is not null and not exists (
    select 1 from public.decks where id = p_target_deck_id and user_id = v_user_id and deleted_at is null
  ) then
    raise exception 'target_deck_id is not owned by the current user';
  end if;

  insert into public.anki_transfer_jobs (
    user_id, direction, storage_path, file_sha256, source_deck_id, target_deck_id, options
  ) values (
    v_user_id, p_direction, p_storage_path, p_file_sha256,
    p_source_deck_id, p_target_deck_id, coalesce(p_options, '{}'::jsonb)
  )
  on conflict (user_id, direction, file_sha256)
    where file_sha256 is not null
  do update set options = excluded.options
  returning id into v_job_id;

  return v_job_id;
end;
$$;

comment on function public.claim_fsrs_optimization_job(uuid) is
  'Atomically claims one queued per-user FSRS optimization run for an authenticated worker.';
comment on function public.claim_fsrs_optimization_job_for_worker(uuid) is
  'Internal service-role claim for a scheduled FSRS optimization worker.';
comment on table public.anki_transfer_jobs is
  'Private metadata for safe .apkg import/export. Binary files live in the anki-transfers Storage bucket.';


-- ================= SOURCE 0019_fsrs_scheduler.sql =================
-- Flashi 0019: optional Supabase-native scheduler for the FSRS optimizer.
-- The cron job is created only after an operator stores flashi_service_role_jwt
-- in Supabase Vault and explicitly calls private.configure_fsrs_optimizer_cron().

create extension if not exists pg_cron;
create extension if not exists pg_net;

create schema if not exists private;

create or replace function private.configure_fsrs_optimizer_cron(
  p_project_url text,
  p_cron text default '*/15 * * * *'
)
returns bigint
language plpgsql
security definer
set search_path = private, public, vault, cron, extensions
as $$
declare
  v_secret text;
  v_job_id bigint;
  v_url text;
begin
  if p_project_url is null or p_project_url !~ '^https://[a-z0-9-]+\.supabase\.co$' then
    raise exception 'p_project_url must be a canonical Supabase project URL';
  end if;
  if p_cron is null or length(trim(p_cron)) = 0 then
    raise exception 'p_cron must not be empty';
  end if;

  select decrypted_secret into v_secret
  from vault.decrypted_secrets
  where name = 'flashi_service_role_jwt'
  limit 1;
  if v_secret is null or length(v_secret) < 20 then
    raise exception 'Vault secret flashi_service_role_jwt is required';
  end if;

  for v_job_id in
    select jobid from cron.job where jobname = 'flashi-fsrs-optimize-worker'
  loop
    perform cron.unschedule(v_job_id);
  end loop;

  v_url := p_project_url || '/functions/v1/fsrs-optimize-worker';
  v_job_id := cron.schedule(
    'flashi-fsrs-optimize-worker',
    p_cron,
    format($cron$
      select net.http_post(
        url := %L,
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'flashi_service_role_jwt' limit 1)
        ),
        body := '{"limit":5}'::jsonb
      );
    $cron$, v_url)
  );
  return v_job_id;
end;
$$;

revoke execute on function private.configure_fsrs_optimizer_cron(text, text) from public, anon, authenticated;
grant execute on function private.configure_fsrs_optimizer_cron(text, text) to postgres, service_role;

comment on function private.configure_fsrs_optimizer_cron(text, text) is
  'Creates or replaces the Supabase-native FSRS optimizer cron job using the Vault secret flashi_service_role_jwt. It stores no JWT in the migration or cron command.';


-- ================= SOURCE 0020_move_pg_net_registration.sql =================
-- Flashi 0020: move pg_net's extension registration namespace out of public.
-- At authoring time the project had no external pg_net dependencies and no
-- queued requests. Dropping/recreating is therefore safe for this deployment.
-- Do not reuse this migration blindly on a database with webhooks or callers
-- that depend on pg_net; back up and inventory those dependencies first.

drop extension if exists pg_net;
create extension if not exists pg_net with schema extensions;
