-- Flashi 20261006221500: corrige dois defeitos confirmados pela auditoria F01–F48.
--
-- F14 — create_anki_transfer_job rejeitava TODOS os caminhos válidos.
--   A validação original usava p_storage_path !~ '.../[^/]+\\.apkg$'. No banco
--   publicado a barra invertida estava duplicada, de modo que a expressão exigia
--   uma barra invertida literal antes de "apkg" e nunca casava com
--   "<user_id>/exports/<arquivo>.apkg".
--   Efeito observado: a RPC sempre levantava
--   'storage_path must be user-scoped under imports or exports and end in .apkg',
--   a exportação Anki respondia 500 (INTERNAL_ERROR) e a importação .apkg
--   falhava antes de qualquer parsing do pacote.
--   Correção: validação equivalente SEM expressão regular, imune a falhas de
--   escape: exatamente três segmentos, prefixo do usuário, diretório
--   imports|exports e sufixo .apkg.
--
-- F02 — replay idempotente devolvia agendamento divergente.
--   record_review_fsrs6_idempotent já é idempotente (retorna o review_logs
--   existente e não insere de novo), mas a Edge Function fsrs-review recalculava
--   o FSRS com o estado já atualizado e devolvia due_at/interval_days diferentes
--   do registro persistido. A função abaixo expõe o registro persistido para que
--   o cliente nunca receba um intervalo que não existe no banco.

create or replace function public.get_review_log_by_client_id(
  p_card_id uuid,
  p_client_review_id uuid
)
returns table (
  review_id uuid,
  card_id uuid,
  rating public.review_rating,
  new_state public.card_state,
  new_interval_days numeric,
  new_due_at timestamptz,
  new_stability numeric,
  new_difficulty numeric,
  reviewed_at timestamptz
)
language sql
security invoker
stable
set search_path = public
as $$
  select
    rl.id,
    rl.card_id,
    rl.rating,
    rl.new_state,
    rl.new_interval_days,
    rl.new_due_at,
    rl.new_stability,
    rl.new_difficulty,
    rl.reviewed_at
  from public.review_logs rl
  where rl.user_id = (select auth.uid())
    and rl.client_review_id = p_client_review_id
    and rl.card_id = p_card_id
  limit 1;
$$;

comment on function public.get_review_log_by_client_id(uuid, uuid) is
  'Returns the persisted review for a client_review_id replay so the API can echo stored scheduling values (F02).';

revoke execute on function public.get_review_log_by_client_id(uuid, uuid) from public, anon;
grant execute on function public.get_review_log_by_client_id(uuid, uuid) to authenticated, service_role;

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