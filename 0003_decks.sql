-- 0003_decks.sql
-- Decks (with subdeck support via self-reference) and collaborators
-- (groundwork for future deck sharing).

create table if not exists public.decks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  parent_deck_id uuid references public.decks(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 120),
  description text,
  icon text,
  visibility public.deck_visibility not null default 'private',
  is_archived boolean not null default false,
  study_config jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint decks_not_self_parent check (parent_deck_id is distinct from id)
);

-- Prevents two active (non-deleted) decks with the same name under the same parent.
create unique index if not exists decks_unique_name_per_parent
  on public.decks (user_id, coalesce(parent_deck_id, '00000000-0000-0000-0000-000000000000'), name)
  where deleted_at is null;

create index if not exists idx_decks_user on public.decks (user_id) where deleted_at is null;
create index if not exists idx_decks_parent on public.decks (parent_deck_id) where deleted_at is null;

-- Deck sharing (future "shared" visibility): explicit grants per user.
create table if not exists public.deck_collaborators (
  deck_id uuid not null references public.decks(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role public.collaborator_role not null default 'viewer',
  created_at timestamptz not null default now(),
  primary key (deck_id, user_id)
);

create index if not exists idx_deck_collaborators_user on public.deck_collaborators (user_id);
