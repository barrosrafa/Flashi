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
