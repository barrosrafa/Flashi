-- Flashi schema snapshot: 01_types_and_identity.sql
-- Enums and identity foundations.
-- Generated from the v1 baseline; historical sources remain in ../migrations_archive/.
-- Apply strictly in lexical order.


-- ================= SOURCE 0001_types.sql =================
-- 0001_types.sql
-- Enum types for the Flashi flashcards schema.
--
-- NOTE: gen_random_uuid() has been native to PostgreSQL since v13
-- (Supabase currently runs PG15+), so the historical `pgcrypto`
-- extension is NOT required and is intentionally omitted here.

do $$ begin
  create type public.card_state as enum ('new', 'learning', 'review', 'relearning');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.review_rating as enum ('again', 'hard', 'good', 'easy');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.deck_visibility as enum ('private', 'shared', 'public');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.srs_algorithm as enum ('sm2', 'fsrs', 'custom');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.media_type as enum ('image', 'audio', 'video', 'other');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.collaborator_role as enum ('viewer', 'editor');
exception when duplicate_object then null; end $$;


-- ================= SOURCE 0002_profiles.sql =================
-- 0002_profiles.sql
-- 1:1 extension of auth.users with app-specific profile data.

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  avatar_url text,
  language text not null default 'pt-BR',
  timezone text not null default 'America/Sao_Paulo',
  settings jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.profiles is
  'Extends auth.users with app-specific profile data (1:1). Row is created automatically by handle_new_user() trigger.';

