-- Flashi: opt-in scheduler for the protected AI ingestion worker.
-- The schedule is not created by this migration. An operator must store both
-- secrets in Supabase Vault and explicitly call the private configuration RPC.
begin;

create schema if not exists private;

create or replace function private.configure_ai_ingestion_cron(
  p_project_url text,
  p_cron text default '*/1 * * * *'
)
returns bigint
language plpgsql
security definer
set search_path = private, public, vault, cron, extensions
as $$
declare
  v_service_jwt text;
  v_worker_secret text;
  v_job_id bigint;
  v_url text;
begin
  if p_project_url is null or p_project_url !~ '^https://[a-z0-9-]+\.supabase\.co$' then
    raise exception 'p_project_url must be a canonical Supabase project URL';
  end if;
  if p_cron not in ('*/1 * * * *', '*/2 * * * *', '*/5 * * * *') then
    raise exception 'p_cron must be one of the supported one, two or five minute schedules';
  end if;

  select decrypted_secret into v_service_jwt
  from vault.decrypted_secrets where name = 'flashi_service_role_jwt' limit 1;
  select decrypted_secret into v_worker_secret
  from vault.decrypted_secrets where name = 'flashi_ingestion_worker_secret' limit 1;
  if v_service_jwt is null or length(v_service_jwt) < 20 then
    raise exception 'Vault secret flashi_service_role_jwt is required';
  end if;
  if v_worker_secret is null or length(v_worker_secret) < 20 then
    raise exception 'Vault secret flashi_ingestion_worker_secret is required';
  end if;

  for v_job_id in
    select jobid from cron.job where jobname = 'flashi-ai-ingestion-worker'
  loop
    perform cron.unschedule(v_job_id);
  end loop;

  v_url := p_project_url || '/functions/v1/ai-ingest-worker';
  v_job_id := cron.schedule(
    'flashi-ai-ingestion-worker',
    p_cron,
    format($cron$
      select net.http_post(
        url := %L,
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'flashi_service_role_jwt' limit 1),
          'x-worker-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'flashi_ingestion_worker_secret' limit 1)
        ),
        body := '{}'::jsonb
      );
    $cron$, v_url)
  );
  return v_job_id;
end;
$$;

revoke execute on function private.configure_ai_ingestion_cron(text, text) from public, anon, authenticated;
grant execute on function private.configure_ai_ingestion_cron(text, text) to postgres, service_role;
comment on function private.configure_ai_ingestion_cron(text, text) is
  'Opt-in scheduler for ai-ingest-worker. Requires service-role JWT and worker secret in Vault; processing is not enabled automatically.';

commit;
