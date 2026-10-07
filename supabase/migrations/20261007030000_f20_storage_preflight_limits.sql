-- Storage probes INSERT before metadata is populated. Enforce bytes/MIME at the
-- Storage bucket boundary, not on metadata that is empty in that preflight.
-- Authentication and owner-folder isolation remain mandatory on all writes.
update storage.buckets
set public=false, file_size_limit=26214400,
 allowed_mime_types=array[
  'image/jpeg','image/png','image/gif','image/webp','image/avif','image/svg+xml',
  'audio/mpeg','audio/ogg','audio/wav','audio/webm','audio/mp4',
  'video/mp4','video/webm','video/quicktime'
 ]
where id='card-media';

drop policy if exists card_media_storage_owner_insert on storage.objects;
create policy card_media_storage_owner_insert on storage.objects
 for insert to authenticated with check (
  bucket_id='card-media' and (storage.foldername(name))[1]=(select auth.uid())::text
 );
drop policy if exists card_media_storage_owner_update on storage.objects;
create policy card_media_storage_owner_update on storage.objects
 for update to authenticated using (
  bucket_id='card-media' and (storage.foldername(name))[1]=(select auth.uid())::text
 ) with check (
  bucket_id='card-media' and (storage.foldername(name))[1]=(select auth.uid())::text
 );
