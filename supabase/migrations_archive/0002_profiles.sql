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
