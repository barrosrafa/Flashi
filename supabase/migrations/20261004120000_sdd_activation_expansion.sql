-- Flashi SDD activation expansion.
-- This migration extends the v2 snapshot instead of creating duplicate contracts:
-- profiles is the existing user_profiles equivalent, ai_ingestion_jobs is the
-- existing asynchronous queue, and leaderboard_entries remains the protected
-- materialized projection already used by the product.
begin;

-- The Edge Function uses service_role for this private cache; no browser
-- object policy is needed because clients receive audio directly from TTS.
insert into storage.buckets (id, name, public)
values ('tts_cache', 'tts_cache', false)
on conflict (id) do nothing;

-- Advanced card metadata -----------------------------------------------------
alter table public.cards add column if not exists type_answer_validation jsonb not null default '{}'::jsonb;

alter table public.cards drop constraint if exists cards_card_kind_check;
alter table public.cards add constraint cards_card_kind_check check (
  card_kind in ('basic', 'reverse', 'cloze', 'image_occlusion', 'type_answer', 'diagram')
  and (card_kind <> 'cloze' or cloze_ordinal is not null)
  and (cloze_ordinal is null or cloze_ordinal > 0)
);

alter table public.note_card_definitions drop constraint if exists note_card_definitions_kind_check;
alter table public.note_card_definitions add constraint note_card_definitions_kind_check check (
  card_kind in ('basic', 'reverse', 'cloze', 'image_occlusion', 'type_answer', 'diagram')
  and (card_kind <> 'cloze' or cloze_ordinal is not null)
  and (cloze_ordinal is null or cloze_ordinal > 0)
);

-- Deck sharing/export preferences --------------------------------------------
alter table public.decks add column if not exists export_formats text[] not null default array['csv', 'apkg', 'json']::text[];
alter table public.decks add column if not exists is_public boolean not null default false;
alter table public.decks add column if not exists share_slug text;
create unique index if not exists decks_share_slug_unique
  on public.decks (share_slug)
  where share_slug is not null and deleted_at is null;

-- Persistent profile preferences. The v2 snapshot calls this table profiles.
alter table public.profiles add column if not exists theme text not null default 'system';
alter table public.profiles add column if not exists accessibility jsonb not null default '{}'::jsonb;
alter table public.profiles add column if not exists tts_voice text not null default 'pt-BR-Neural';
alter table public.profiles add column if not exists tts_speed numeric not null default 1.0;
alter table public.profiles drop constraint if exists profiles_theme_check;
alter table public.profiles add constraint profiles_theme_check check (theme in ('light', 'dark', 'system', 'brutalist', 'minimal'));
alter table public.profiles drop constraint if exists profiles_tts_speed_check;
alter table public.profiles add constraint profiles_tts_speed_check check (tts_speed > 0 and tts_speed <= 4);

-- Additive fields for the existing queued AI ingestion contract.
alter table public.ai_ingestion_jobs add column if not exists source_url text;
alter table public.ai_ingestion_jobs add column if not exists source_storage_path text;
alter table public.ai_ingestion_jobs add column if not exists result_note_ids uuid[] not null default '{}'::uuid[];

-- Per-card translation cache -------------------------------------------------
create table if not exists public.card_translations (
  id uuid primary key default gen_random_uuid(),
  card_id uuid not null references public.cards(id) on delete cascade,
  target_language text not null check (char_length(target_language) between 2 and 20),
  translated_front text,
  translated_back text,
  provider text not null check (provider in ('deepl', 'google')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (card_id, target_language)
);
create index if not exists idx_card_translations_card on public.card_translations(card_id);
alter table public.card_translations enable row level security;
drop policy if exists card_translations_owner_all on public.card_translations;
create policy card_translations_owner_all on public.card_translations
  for all using (exists (
    select 1 from public.cards c
    where c.id = card_translations.card_id and c.user_id = auth.uid()
  )) with check (exists (
    select 1 from public.cards c
    where c.id = card_translations.card_id and c.user_id = auth.uid()
  ));

-- Game session events ---------------------------------------------------------
create table if not exists public.game_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  deck_id uuid not null references public.decks(id) on delete cascade,
  game_type text not null check (game_type in ('match', 'gravity', 'blast', 'live')),
  score integer not null default 0 check (score >= 0),
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  deleted_at timestamptz
);
create index if not exists idx_game_sessions_user_deck on public.game_sessions(user_id, deck_id, started_at desc);
alter table public.game_sessions enable row level security;
drop policy if exists game_sessions_owner_all on public.game_sessions;
create policy game_sessions_owner_all on public.game_sessions
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Webhook subscriptions and hashed API identities ----------------------------
create table if not exists public.webhook_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  url text not null check (url ~ '^https://'),
  events text[] not null default '{}'::text[],
  secret text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_webhook_subscriptions_user on public.webhook_subscriptions(user_id, active);
alter table public.webhook_subscriptions enable row level security;
drop policy if exists webhook_subscriptions_owner_all on public.webhook_subscriptions;
create policy webhook_subscriptions_owner_all on public.webhook_subscriptions
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

create table if not exists public.api_keys (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  key_hash text not null unique,
  name text not null check (char_length(name) between 1 and 120),
  scopes text[] not null default '{}'::text[],
  last_used_at timestamptz,
  expires_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists idx_api_keys_user on public.api_keys(user_id, created_at desc);
alter table public.api_keys enable row level security;
drop policy if exists api_keys_owner_all on public.api_keys;
create policy api_keys_owner_all on public.api_keys
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

comment on table public.card_translations is 'Per-card translation cache with one target language per card.';
comment on table public.game_sessions is 'User-owned game results used by future Match/Gravity/Blast modes.';
comment on table public.webhook_subscriptions is 'User-owned HTTPS webhook endpoints; payloads are signed with HMAC-SHA256.';
comment on table public.api_keys is 'User-owned integration identities; only irreversible key hashes are stored.';
comment on column public.profiles.theme is 'Persistent theme preference; profiles is the v2 equivalent of user_profiles.';
comment on column public.ai_ingestion_jobs.source_reference is 'Existing queue field; source_url and source_storage_path are additive SDD projections.';
comment on materialized view public.leaderboard_entries is 'Protected leaderboard projection; the v2 contract intentionally keeps it as a materialized view rather than duplicating it as a table.';

commit;
