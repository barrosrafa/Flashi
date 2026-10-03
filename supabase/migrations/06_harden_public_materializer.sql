-- Restrict the SECURITY DEFINER import materializer to authenticated callers.
-- Applied to project flashi during deployment of backend v2.

revoke execute on function public.materialize_import_batch(uuid, uuid, uuid, jsonb) from public;
revoke execute on function public.materialize_import_batch(uuid, uuid, uuid, jsonb) from anon;
grant execute on function public.materialize_import_batch(uuid, uuid, uuid, jsonb) to authenticated;
grant execute on function public.materialize_import_batch(uuid, uuid, uuid, jsonb) to service_role;
