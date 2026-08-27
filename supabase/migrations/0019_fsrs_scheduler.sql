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
