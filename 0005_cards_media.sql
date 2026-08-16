-- 0005_cards_media.sql
-- Cards are content only. Per-user study state lives in
-- card_learning_state (0006) so shared/public decks work correctly.

create table if not exists public.cards (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade, -- content owner/author
  deck_id uuid not null references public.decks(id) on delete cascade,
  template_id uuid references public.card_templates(id) on delete set null,
  note_group_id uuid not null default gen_random_uuid(), -- groups cards generated from the same note
  fields jsonb not null default '{}'::jsonb,              -- e.g. {"Front": "...", "Back": "...", "Extra": "..."}
  is_archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint cards_fields_not_empty check (fields <> '{}'::jsonb)
);

create index if not exists idx_cards_deck on public.cards (deck_id) where deleted_at is null;
create index if not exists idx_cards_user on public.cards (user_id) where deleted_at is null;
create index if not exists idx_cards_note_group on public.cards (note_group_id);
-- Supports free-text search across card fields (e.g. "find cards containing X").
create index if not exists idx_cards_fields_gin on public.cards using gin (fields jsonb_path_ops);

create table if not exists public.card_tags (
  card_id uuid not null references public.cards(id) on delete cascade,
  tag_id uuid not null references public.tags(id) on delete cascade,
  primary key (card_id, tag_id)
);

create index if not exists idx_card_tags_tag on public.card_tags (tag_id);

create table if not exists public.card_media (
  id uuid primary key default gen_random_uuid(),
  card_id uuid not null references public.cards(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  field_name text,             -- which field this media is attached to (e.g. "Front")
  media_type public.media_type not null,
  storage_path text not null,  -- path inside the 'card-media' Supabase Storage bucket
  file_size_bytes bigint,
  mime_type text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists idx_card_media_card on public.card_media (card_id);
create index if not exists idx_card_media_user on public.card_media (user_id);
