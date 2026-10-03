-- Private bucket required by the import-deck Edge Function.
-- Paths are scoped to the authenticated user: <auth.uid()>/...

insert into storage.buckets (id, name, public)
values ('import-media', 'import-media', false)
on conflict (id) do nothing;

drop policy if exists "import_media_owner_select" on storage.objects;
create policy "import_media_owner_select" on storage.objects
  for select using (
    bucket_id = 'import-media'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "import_media_owner_insert" on storage.objects;
create policy "import_media_owner_insert" on storage.objects
  for insert with check (
    bucket_id = 'import-media'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "import_media_owner_update" on storage.objects;
create policy "import_media_owner_update" on storage.objects
  for update using (
    bucket_id = 'import-media'
    and (storage.foldername(name))[1] = auth.uid()::text
  ) with check (
    bucket_id = 'import-media'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "import_media_owner_delete" on storage.objects;
create policy "import_media_owner_delete" on storage.objects
  for delete using (
    bucket_id = 'import-media'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
