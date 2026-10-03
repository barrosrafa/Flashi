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
  if p_storage_path is null or p_storage_path !~ ('^' || v_user_id::text || '/(imports|exports)/[^/]+\\.apkg$') then
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
