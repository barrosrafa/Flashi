-- 0009_rls_policies.sql
-- Row Level Security for every user-owned table. Never rely on the
-- frontend for authorization -- these policies are the actual boundary.

alter table public.profiles enable row level security;
alter table public.decks enable row level security;
alter table public.deck_collaborators enable row level security;
alter table public.tags enable row level security;
alter table public.card_templates enable row level security;
alter table public.cards enable row level security;
alter table public.card_tags enable row level security;
alter table public.card_media enable row level security;
alter table public.card_learning_state enable row level security;
alter table public.review_logs enable row level security;
alter table public.study_settings enable row level security;
alter table public.user_deck_settings enable row level security;
alter table public.daily_statistics enable row level security;

-- profiles ------------------------------------------------------------
drop policy if exists profiles_self on public.profiles;
create policy profiles_self on public.profiles
  for all using (auth.uid() = id) with check (auth.uid() = id);

-- decks -----------------------------------------------------------------
-- Deliberately NO delete policy: end users can only soft-delete
-- (update deleted_at via soft_delete_deck(), see 0010). Hard deletes
-- are only possible via service_role, which bypasses RLS entirely.
drop policy if exists decks_select on public.decks;
create policy decks_select on public.decks
  for select using (auth.uid() = user_id);

drop policy if exists decks_insert on public.decks;
create policy decks_insert on public.decks
  for insert with check (auth.uid() = user_id);

drop policy if exists decks_update on public.decks;
create policy decks_update on public.decks
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists decks_public_read on public.decks;
create policy decks_public_read on public.decks
  for select using (visibility = 'public' and deleted_at is null);

drop policy if exists decks_shared_read on public.decks;
create policy decks_shared_read on public.decks
  for select using (
    exists (
      select 1 from public.deck_collaborators dc
      where dc.deck_id = decks.id and dc.user_id = auth.uid()
    )
  );

-- deck_collaborators ------------------------------------------------------
drop policy if exists deck_collaborators_owner_manage on public.deck_collaborators;
create policy deck_collaborators_owner_manage on public.deck_collaborators
  for all using (
    exists (select 1 from public.decks d where d.id = deck_collaborators.deck_id and d.user_id = auth.uid())
  ) with check (
    exists (select 1 from public.decks d where d.id = deck_collaborators.deck_id and d.user_id = auth.uid())
  );

drop policy if exists deck_collaborators_self_read on public.deck_collaborators;
create policy deck_collaborators_self_read on public.deck_collaborators
  for select using (auth.uid() = user_id);

-- tags --------------------------------------------------------------------
drop policy if exists tags_owner on public.tags;
create policy tags_owner on public.tags
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- card_templates ------------------------------------------------------------
drop policy if exists templates_owner on public.card_templates;
create policy templates_owner on public.card_templates
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists templates_system_read on public.card_templates;
create policy templates_system_read on public.card_templates
  for select using (is_system = true);

-- cards ---------------------------------------------------------------------
-- Same no-delete-for-end-users pattern as decks.
drop policy if exists cards_select on public.cards;
create policy cards_select on public.cards
  for select using (auth.uid() = user_id);

drop policy if exists cards_insert on public.cards;
create policy cards_insert on public.cards
  for insert with check (auth.uid() = user_id);

drop policy if exists cards_update on public.cards;
create policy cards_update on public.cards
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists cards_public_read on public.cards;
create policy cards_public_read on public.cards
  for select using (
    exists (
      select 1 from public.decks d
      where d.id = cards.deck_id and d.visibility = 'public' and d.deleted_at is null
    )
  );

drop policy if exists cards_shared_read on public.cards;
create policy cards_shared_read on public.cards
  for select using (
    exists (
      select 1 from public.deck_collaborators dc
      where dc.deck_id = cards.deck_id and dc.user_id = auth.uid()
    )
  );

-- card_tags (ownership derived from the card) --------------------------------
drop policy if exists card_tags_owner on public.card_tags;
create policy card_tags_owner on public.card_tags
  for all using (
    exists (select 1 from public.cards c where c.id = card_tags.card_id and c.user_id = auth.uid())
  ) with check (
    exists (select 1 from public.cards c where c.id = card_tags.card_id and c.user_id = auth.uid())
  );

-- card_media ------------------------------------------------------------------
drop policy if exists card_media_owner on public.card_media;
create policy card_media_owner on public.card_media
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- card_learning_state -----------------------------------------------------------
-- Always strictly private to the studier, even on public/shared decks:
-- your SRS progress on someone else's deck is never someone else's business.
drop policy if exists learning_state_owner on public.card_learning_state;
create policy learning_state_owner on public.card_learning_state
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- review_logs ---------------------------------------------------------------------
-- INSERT + SELECT only. No UPDATE/DELETE policy exists at all, so those
-- operations are denied outright for authenticated users (belt-and-suspenders
-- with the trigger in 0008).
drop policy if exists review_logs_select on public.review_logs;
create policy review_logs_select on public.review_logs
  for select using (auth.uid() = user_id);

drop policy if exists review_logs_insert on public.review_logs;
create policy review_logs_insert on public.review_logs
  for insert with check (auth.uid() = user_id);

-- study_settings ------------------------------------------------------------------
drop policy if exists study_settings_owner on public.study_settings;
create policy study_settings_owner on public.study_settings
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- user_deck_settings ----------------------------------------------------------------
drop policy if exists user_deck_settings_owner on public.user_deck_settings;
create policy user_deck_settings_owner on public.user_deck_settings
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- daily_statistics --------------------------------------------------------------------
drop policy if exists daily_stats_owner on public.daily_statistics;
create policy daily_stats_owner on public.daily_statistics
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
