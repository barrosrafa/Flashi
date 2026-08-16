-- 0004_tags_templates.sql

create table if not exists public.tags (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 60),
  color text,
  created_at timestamptz not null default now(),
  unique (user_id, name)
);

create index if not exists idx_tags_user on public.tags (user_id);

-- card_templates: lightweight note-type system. Rather than a full
-- Anki-style note/card separation (one note generating N reviewable
-- cards via templates), this models a single flexible `fields` JSONB
-- per card plus a template that documents the expected field names
-- and how they should render. This covers Basic, Basic+Reverse and
-- Cloze use cases without the added complexity of multi-card
-- generation per note -- flagged in README as a deliberate scope cut.
create table if not exists public.card_templates (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade, -- null = system template, usable by everyone
  name text not null,
  field_definitions jsonb not null default '[{"name":"Front"},{"name":"Back"}]'::jsonb,
  card_generation jsonb not null default '[{"name":"Card 1","front":"{{Front}}","back":"{{Back}}"}]'::jsonb,
  is_system boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_card_templates_user on public.card_templates (user_id);
