-- 0011_storage.sql
-- Supabase Storage bucket for card media. Files must be uploaded under
-- {auth.uid()}/... so the RLS policy below can scope access per user.

insert into storage.buckets (id, name, public)
values ('card-media', 'card-media', false)
on conflict (id) do nothing;

drop policy if exists "card_media_storage_owner_select" on storage.objects;
create policy "card_media_storage_owner_select" on storage.objects
  for select using (
    bucket_id = 'card-media'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "card_media_storage_owner_insert" on storage.objects;
create policy "card_media_storage_owner_insert" on storage.objects
  for insert with check (
    bucket_id = 'card-media'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "card_media_storage_owner_delete" on storage.objects;
create policy "card_media_storage_owner_delete" on storage.objects
  for delete using (
    bucket_id = 'card-media'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
