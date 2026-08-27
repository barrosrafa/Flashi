-- Flashi 0022: restrict image-occlusion materialization to authenticated users.
-- The RPC validates auth.uid() and ownership internally, but it should not
-- retain the default PUBLIC EXECUTE privilege of a SECURITY DEFINER function.

revoke execute on function public.create_image_occlusion_note(uuid, jsonb) from public, anon;
grant execute on function public.create_image_occlusion_note(uuid, jsonb) to authenticated;
