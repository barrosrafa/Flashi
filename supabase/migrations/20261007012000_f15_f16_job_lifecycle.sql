alter table public.ai_ingestion_jobs add column if not exists attempt_count integer not null default 0;
alter table public.ai_ingestion_jobs add column if not exists heartbeat_at timestamptz;
alter table public.ai_ingestion_jobs add column if not exists result_draft jsonb;
alter table public.fsrs_optimization_runs add column if not exists attempt_count integer not null default 0;
alter table public.fsrs_optimization_runs add column if not exists heartbeat_at timestamptz;

create or replace function public.job_claim_heartbeat() returns trigger language plpgsql set search_path=public as $$
begin
 if new.status::text in ('processing','running') and old.status::text='queued' and old.status is distinct from new.status then
   new.attempt_count:=old.attempt_count+1; new.heartbeat_at:=now();
 end if;
 return new;
end $$;
drop trigger if exists ai_job_claim_heartbeat on public.ai_ingestion_jobs;
create trigger ai_job_claim_heartbeat before update on public.ai_ingestion_jobs for each row execute function public.job_claim_heartbeat();
drop trigger if exists fsrs_job_claim_heartbeat on public.fsrs_optimization_runs;
create trigger fsrs_job_claim_heartbeat before update on public.fsrs_optimization_runs for each row execute function public.job_claim_heartbeat();

create or replace function public.control_worker_job(p_job_type text,p_job_id uuid,p_action text)
returns boolean language plpgsql security invoker set search_path=public as $$
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
 if p_action not in ('retry','cancel') then raise exception 'JOB_ACTION_INVALID'; end if;
 if p_job_type='ai' then
   if p_action='cancel' then
     update public.ai_ingestion_jobs set status='cancelled',updated_at=now() where id=p_job_id and user_id=auth.uid() and status::text in ('queued','processing','awaiting_review');
   else
     update public.ai_ingestion_jobs set status='queued',error_message=null,updated_at=now()
     where id=p_job_id and user_id=auth.uid() and (status::text in ('failed','cancelled') or (status::text in ('queued','processing') and coalesce(heartbeat_at,updated_at)<now()-interval '5 minutes'));
   end if;
 elsif p_job_type='fsrs' then
   if p_action='cancel' then
     update public.fsrs_optimization_runs set status='cancelled',completed_at=now() where id=p_job_id and user_id=auth.uid() and status in ('queued','running');
   else
     update public.fsrs_optimization_runs set status='queued',error_message=null,started_at=null,completed_at=null,requested_at=now()
     where id=p_job_id and user_id=auth.uid() and (status in ('failed','cancelled') or (status in ('queued','running') and coalesce(heartbeat_at,requested_at)<now()-interval '5 minutes'));
   end if;
 else raise exception 'JOB_TYPE_INVALID'; end if;
 if not found then raise exception 'JOB_NOT_OWNED_OR_NOT_RECOVERABLE'; end if;
 return true;
end $$;
revoke all on function public.control_worker_job(text,uuid,text) from public,anon;
grant execute on function public.control_worker_job(text,uuid,text) to authenticated;

create or replace function public.publish_ai_ingestion_draft(p_job_id uuid,p_selected_indices integer[])
returns table(notes_count integer,cards_count integer) language plpgsql security definer set search_path=public as $$
declare job public.ai_ingestion_jobs%rowtype; selected jsonb;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
 select * into job from public.ai_ingestion_jobs where id=p_job_id and user_id=auth.uid() and deleted_at is null for update;
 if not found then raise exception 'JOB_NOT_FOUND'; end if;
 if job.status='completed' then return query select job.notes_generated_count,job.cards_generated_count; return; end if;
 if job.status<>'awaiting_review' or jsonb_typeof(job.result_draft)<>'array' then raise exception 'AI_DRAFT_NOT_READY'; end if;
 if coalesce(array_length(p_selected_indices,1),0)=0 then raise exception 'AI_SELECTION_REQUIRED'; end if;
 if exists(select 1 from unnest(p_selected_indices) i where i<0 or i>=jsonb_array_length(job.result_draft)) then raise exception 'AI_SELECTION_INVALID'; end if;
 select jsonb_agg(value order by ordinal) into selected from jsonb_array_elements(job.result_draft) with ordinality draft(value,ordinal) where (ordinal-1)::integer=any(p_selected_indices);
 -- Only this explicitly invoked RPC may publish generated suggestions.
 update public.ai_ingestion_jobs set status='processing',updated_at=now() where id=job.id;
 return query select * from public.materialize_ai_ingestion_batch(job.id,job.user_id,job.deck_id,selected);
end $$;
revoke all on function public.publish_ai_ingestion_draft(uuid,integer[]) from public,anon;
grant execute on function public.publish_ai_ingestion_draft(uuid,integer[]) to authenticated;

-- Retrying a terminal optimizer run with unchanged review count must not
-- silently return the old terminal result.
do $$
declare definition text;
begin
 select pg_get_functiondef(p.oid) into definition from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='enqueue_fsrs_optimization' limit 1;
 definition:=replace(definition,'  if v_run_id is not null then',E'  if v_run_id is not null then\n    update public.fsrs_optimization_runs set status=''queued'', error_message=null, started_at=null, completed_at=null, requested_at=now() where id=v_run_id and status in (''failed'',''cancelled'');');
 execute definition;
end $$;

create or replace function public.claim_ai_ingestion_job_by_id(p_job_id uuid)
returns table(job_id uuid,user_id uuid,deck_id uuid,source_type public.generation_source_type,source_reference text)
language sql security definer set search_path=public as $$
 with candidate as (select j.id from public.ai_ingestion_jobs j where j.id=p_job_id and j.status='queued' and j.deleted_at is null for update skip locked)
 update public.ai_ingestion_jobs j set status='processing',updated_at=now(),error_message=null from candidate c where j.id=c.id returning j.id,j.user_id,j.deck_id,j.source_type,j.source_reference;
$$;
revoke all on function public.claim_ai_ingestion_job_by_id(uuid) from public,anon,authenticated;
grant execute on function public.claim_ai_ingestion_job_by_id(uuid) to service_role;
