-- Flashi 0023: remove avoidable SECURITY DEFINER/search_path warnings.
-- Image occlusion already performs owner validation and all writes are covered
-- by authenticated-user RLS, so it does not need definer privileges.

alter function public.get_incremental_sync(bigint, integer)
  set search_path = public;

alter function public.create_image_occlusion_note(uuid, jsonb)
  security invoker;
