-- Flashi 0017: remove recursive RLS evaluation from shared-deck policies
-- and add the remaining foreign-key indexes reported by the performance advisor.

create schema if not exists private;

-- These helpers run with the migration owner so policy evaluation can inspect
-- the relationship tables without recursively evaluating their own policies.
-- They only answer membership/ownership for the current JWT subject.
create or replace function private.is_deck_owner(p_deck_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.decks d
    where d.id = p_deck_id
      and d.user_id = (select auth.uid())
  );
$$;

create or replace function private.is_deck_collaborator(p_deck_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.deck_collaborators dc
    where dc.deck_id = p_deck_id
      and dc.user_id = (select auth.uid())
  );
$$;

grant usage on schema private to public;
grant execute on function private.is_deck_owner(uuid) to public;
grant execute on function private.is_deck_collaborator(uuid) to public;

-- Replace the mutually recursive policies with calls to the isolated helpers.
drop policy if exists deck_collaborators_owner_manage on public.deck_collaborators;
create policy deck_collaborators_owner_manage on public.deck_collaborators
  for all using (private.is_deck_owner(deck_collaborators.deck_id))
  with check (private.is_deck_owner(deck_collaborators.deck_id));

drop policy if exists decks_shared_read on public.decks;
create policy decks_shared_read on public.decks
  for select using (private.is_deck_collaborator(decks.id));

drop policy if exists cards_shared_read on public.cards;
create policy cards_shared_read on public.cards
  for select using (private.is_deck_collaborator(cards.deck_id));

-- Cover the FK columns highlighted by the performance advisor.
create index if not exists idx_anki_transfer_jobs_source_deck
  on public.anki_transfer_jobs (source_deck_id);
create index if not exists idx_anki_transfer_jobs_target_deck
  on public.anki_transfer_jobs (target_deck_id);
create index if not exists idx_card_learning_state_card
  on public.card_learning_state (card_id);
create index if not exists idx_cards_template
  on public.cards (template_id)
  where template_id is not null;
create index if not exists idx_notes_template
  on public.notes (template_id)
  where template_id is not null;
create index if not exists idx_user_deck_settings_deck
  on public.user_deck_settings (deck_id);
