-- 0008_triggers_functions.sql

-- Generic updated_at maintenance.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_profiles_updated_at on public.profiles;
create trigger trg_profiles_updated_at before update on public.profiles
  for each row execute function public.set_updated_at();

drop trigger if exists trg_decks_updated_at on public.decks;
create trigger trg_decks_updated_at before update on public.decks
  for each row execute function public.set_updated_at();

drop trigger if exists trg_card_templates_updated_at on public.card_templates;
create trigger trg_card_templates_updated_at before update on public.card_templates
  for each row execute function public.set_updated_at();

drop trigger if exists trg_cards_updated_at on public.cards;
create trigger trg_cards_updated_at before update on public.cards
  for each row execute function public.set_updated_at();

drop trigger if exists trg_learning_state_updated_at on public.card_learning_state;
create trigger trg_learning_state_updated_at before update on public.card_learning_state
  for each row execute function public.set_updated_at();

drop trigger if exists trg_study_settings_updated_at on public.study_settings;
create trigger trg_study_settings_updated_at before update on public.study_settings
  for each row execute function public.set_updated_at();

drop trigger if exists trg_user_deck_settings_updated_at on public.user_deck_settings;
create trigger trg_user_deck_settings_updated_at before update on public.user_deck_settings
  for each row execute function public.set_updated_at();

-- Provisions profile + default study settings whenever a new Supabase Auth user is created.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id) values (new.id)
  on conflict (id) do nothing;

  insert into public.study_settings (user_id) values (new.id)
  on conflict (user_id) do nothing;

  return new;
end;
$$;

drop trigger if exists trg_auth_user_created on auth.users;
create trigger trg_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Defense-in-depth: review_logs must be immutable even against direct
-- SQL (RLS in 0009 already blocks it at the API level; this blocks it
-- at the table level too, e.g. against service_role misuse).
create or replace function public.prevent_review_log_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception 'review_logs is append-only: % is not allowed', tg_op;
end;
$$;

drop trigger if exists trg_review_logs_no_update on public.review_logs;
create trigger trg_review_logs_no_update
  before update or delete on public.review_logs
  for each row execute function public.prevent_review_log_mutation();
