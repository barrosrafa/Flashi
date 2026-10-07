-- Flashi 0028: secure, pending collaboration invitations (F25/F44).
-- This migration deliberately does not call an email provider.  The create RPC
-- returns a one-time token to the authorized deck owner so the UI can present a
-- copyable pending invite instead of silently sending a real message.

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.deck_collaboration_invites (
  id uuid primary key default gen_random_uuid(),
  deck_id uuid not null references public.decks(id) on delete cascade,
  inviter_id uuid not null references auth.users(id) on delete cascade,
  email_normalized text not null,
  display_name text,
  invite_context text,
  role public.collaborator_role not null default 'viewer',
  token_hash text not null unique,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '24 hours'),
  used_at timestamptz,
  used_by uuid references auth.users(id) on delete set null,
  constraint deck_collaboration_invites_email_check check (
    char_length(email_normalized) between 3 and 320
    and email_normalized = lower(btrim(email_normalized))
  ),
  constraint deck_collaboration_invites_name_check check (
    display_name is null or char_length(display_name) between 1 and 120
  ),
  constraint deck_collaboration_invites_context_check check (
    invite_context is null or char_length(invite_context) between 1 and 500
  ),
  constraint deck_collaboration_invites_expiry_check check (
    expires_at > created_at and expires_at <= created_at + interval '24 hours'
  )
);

create index if not exists idx_deck_collaboration_invites_deck_created
  on public.deck_collaboration_invites (deck_id, created_at desc);
create index if not exists idx_deck_collaboration_invites_email_expiry
  on public.deck_collaboration_invites (email_normalized, expires_at)
  where used_at is null;

alter table public.deck_collaboration_invites enable row level security;

-- Owners may inspect their own pending records if a future management screen
-- needs them.  There is intentionally no policy for inserting/updating/deleting
-- rows: all mutation and token handling stays in the security-definer RPCs.
drop policy if exists deck_collaboration_invites_owner_read on public.deck_collaboration_invites;
create policy deck_collaboration_invites_owner_read
  on public.deck_collaboration_invites
  for select using (
    exists (
      select 1
      from public.decks d
      where d.id = deck_collaboration_invites.deck_id
        and d.user_id = (select auth.uid())
    )
  );

revoke all on table public.deck_collaboration_invites from public, anon, authenticated;

create or replace function public.create_deck_collaboration_invite(
  p_deck_id uuid,
  p_email text,
  p_display_name text default null,
  p_context text default null,
  p_role public.collaborator_role default 'viewer'
)
returns table (
  invite_id uuid,
  invite_token text,
  expires_at timestamptz,
  delivery_status text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_name text := nullif(btrim(coalesce(p_display_name, '')), '');
  v_context text := nullif(btrim(coalesce(p_context, '')), '');
  v_token text;
  v_invite_id uuid;
  v_expires_at timestamptz;
begin
  -- Keep unauthorized callers on one indistinguishable boundary.  In
  -- particular, this function never looks up auth.users by the supplied email.
  if v_user_id is null
     or p_deck_id is null
     or not exists (
       select 1 from public.decks d
       where d.id = p_deck_id
         and d.user_id = v_user_id
         and d.deleted_at is null
     ) then
    raise exception 'COLLABORATION_INVITE_NOT_AVAILABLE';
  end if;

  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$'
     or char_length(v_email) > 320
     or (v_name is not null and char_length(v_name) > 120)
     or (v_context is not null and char_length(v_context) > 500) then
    raise exception 'COLLABORATION_INVITE_INPUT_INVALID';
  end if;

  -- The raw token is returned once to the authorized owner only.  The
  -- database stores only its SHA-256 digest, so a table read cannot redeem it.
  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.deck_collaboration_invites (
    deck_id, inviter_id, email_normalized, display_name, invite_context,
    role, token_hash
  ) values (
    p_deck_id, v_user_id, v_email, v_name, v_context, p_role,
    encode(extensions.digest(v_token, 'sha256'), 'hex')
  )
  returning id, deck_collaboration_invites.expires_at
  into v_invite_id, v_expires_at;

  -- No provider is configured here: callers must explicitly copy/share this
  -- pending token.  No email is sent by this RPC.
  return query select v_invite_id, v_token, v_expires_at, 'pending_copy'::text;
end;
$$;

create or replace function public.accept_deck_collaboration_invite(p_invite_token text)
returns table (
  deck_id uuid,
  role public.collaborator_role
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_invite public.deck_collaboration_invites%rowtype;
  v_hash text;
  v_email text;
begin
  -- Every failure below intentionally has the same message.  A recipient who
  -- is not the target cannot learn whether a token, account, or email exists.
  if v_user_id is null
     or p_invite_token is null
     or char_length(p_invite_token) <> 64 then
    raise exception 'COLLABORATION_INVITE_INVALID_OR_EXPIRED';
  end if;

  v_hash := encode(extensions.digest(p_invite_token, 'sha256'), 'hex');
  select i.*
  into v_invite
  from public.deck_collaboration_invites i
  join auth.users u
    on u.id = v_user_id
   and lower(btrim(coalesce(u.email, ''))) = i.email_normalized
  where i.token_hash = v_hash
    and i.used_at is null
    and i.expires_at > now()
    and i.inviter_id <> v_user_id
    and exists(select 1 from public.decks d where d.id=i.deck_id and d.user_id=i.inviter_id and d.deleted_at is null)
  for update;

  if not found then
    raise exception 'COLLABORATION_INVITE_INVALID_OR_EXPIRED';
  end if;

  insert into public.deck_collaborators (deck_id, user_id, role)
  values (v_invite.deck_id, v_user_id, v_invite.role)
  on conflict (deck_id, user_id) do update set role = excluded.role;

  update public.deck_collaboration_invites
  set used_at = now(), used_by = v_user_id
  where id = v_invite.id and used_at is null;

  if not found then
    raise exception 'COLLABORATION_INVITE_INVALID_OR_EXPIRED';
  end if;

  return query select v_invite.deck_id, v_invite.role;
end;
$$;

revoke all on function public.create_deck_collaboration_invite(uuid, text, text, text, public.collaborator_role) from public, anon;
revoke all on function public.accept_deck_collaboration_invite(text) from public, anon;
grant execute on function public.create_deck_collaboration_invite(uuid, text, text, text, public.collaborator_role) to authenticated;
grant execute on function public.accept_deck_collaboration_invite(text) to authenticated;

comment on table public.deck_collaboration_invites is
  'Pending, one-time collaboration invitations. Raw tokens are never persisted and no email provider is invoked.';
comment on function public.create_deck_collaboration_invite(uuid, text, text, text, public.collaborator_role) is
  'Owner-authorized pending invite creation. Returns a copyable one-time token; never resolves or discloses email existence.';
comment on function public.accept_deck_collaboration_invite(text) is
  'Consumes a short-lived invite once, only when the authenticated email matches, with generic invalid/expired errors.';
