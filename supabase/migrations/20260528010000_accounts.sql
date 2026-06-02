-- 20260528010000_accounts.sql
-- Account-System mit PIN-Authentifizierung (4-6 Ziffern).
-- Gastspielen bleibt parallel möglich.

create extension if not exists pgcrypto;
create extension if not exists citext;

-- ============================================================
--  TABELLEN
-- ============================================================
create table if not exists public.accounts (
  id uuid primary key default gen_random_uuid(),
  username citext not null unique,
  pin_hash text not null,
  avatar_emoji text not null default '🦊',
  created_at timestamptz not null default now(),
  last_login_at timestamptz,
  constraint accounts_username_format check (username ~* '^[a-z0-9_-]{3,20}$')
);

create table if not exists public.account_sessions (
  token uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '30 days')
);

create index if not exists account_sessions_account_id_idx on public.account_sessions(account_id);
create index if not exists account_sessions_expires_at_idx on public.account_sessions(expires_at);

-- game_players bekommt optionalen Account-Verweis
alter table public.game_players add column if not exists account_id uuid references public.accounts(id) on delete set null;

-- ============================================================
--  PUBLIC VIEW (verbirgt pin_hash)
-- ============================================================
drop view if exists public.accounts_public cascade;
create view public.accounts_public as
  select id, username, avatar_emoji, created_at
  from public.accounts;
grant select on public.accounts_public to anon, authenticated;

-- ============================================================
--  RLS
-- ============================================================
alter table public.accounts enable row level security;
alter table public.account_sessions enable row level security;

drop policy if exists "accounts_select_all" on public.accounts;
create policy "accounts_select_all" on public.accounts for select to anon, authenticated using (true);

-- Sessions sind nur via RPC nutzbar - kein direkter Zugriff fuer anon
drop policy if exists "account_sessions_select_none" on public.account_sessions;

-- ============================================================
--  HILFSFUNKTIONEN
-- ============================================================
create or replace function public.account_normalize_username(value text)
returns text language sql immutable as $$
  select lower(trim(coalesce(value, '')));
$$;

create or replace function public.account_validate_pin(value text)
returns boolean language sql immutable as $$
  select value ~ '^[0-9]{4,6}$';
$$;

-- Hash/Verify mit explizitem Extension-Schema-Lookup
create or replace function public.account_hash_pin(p_pin text)
returns text language plpgsql security definer
set search_path = public, extensions
as $$
declare v_hash text;
begin
  -- Versuche extensions.gen_salt, fallback auf normales gen_salt
  begin
    v_hash := extensions.crypt(p_pin, extensions.gen_salt('bf', 10));
  exception when undefined_function then
    v_hash := crypt(p_pin, gen_salt('bf', 10));
  end;
  return v_hash;
end;
$$;

create or replace function public.account_verify_pin(p_pin text, p_hash text)
returns boolean language plpgsql security definer
set search_path = public, extensions
as $$
declare v_result boolean;
begin
  begin
    v_result := p_hash = extensions.crypt(p_pin, p_hash);
  exception when undefined_function then
    v_result := p_hash = crypt(p_pin, p_hash);
  end;
  return v_result;
end;
$$;

-- ============================================================
--  RPC: register_account
-- ============================================================
drop function if exists public.register_account(text, text, text);
create or replace function public.register_account(
  p_username text,
  p_pin text,
  p_avatar_emoji text default null
)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_user text;
  v_account public.accounts;
  v_session public.account_sessions;
  v_avatar text;
begin
  v_user := public.account_normalize_username(p_username);
  if length(v_user) < 3 or length(v_user) > 20 then
    raise exception 'Benutzername muss 3-20 Zeichen lang sein.';
  end if;
  if v_user !~ '^[a-z0-9_-]+$' then
    raise exception 'Benutzername darf nur Buchstaben, Ziffern, _ oder - enthalten.';
  end if;
  if not public.account_validate_pin(p_pin) then
    raise exception 'PIN muss 4-6 Ziffern lang sein.';
  end if;

  -- Existiert schon?
  if exists (select 1 from public.accounts where username = v_user) then
    raise exception 'Benutzername "%" ist bereits vergeben.', v_user;
  end if;

  v_avatar := coalesce(nullif(trim(p_avatar_emoji), ''), '🦊');
  if char_length(v_avatar) > 8 then v_avatar := '🦊'; end if;

  insert into public.accounts (username, pin_hash, avatar_emoji)
    values (v_user, public.account_hash_pin(p_pin), v_avatar)
    returning * into v_account;

  insert into public.account_sessions (account_id)
    values (v_account.id)
    returning * into v_session;

  return jsonb_build_object(
    'account', jsonb_build_object(
      'id', v_account.id,
      'username', v_account.username,
      'avatar_emoji', v_account.avatar_emoji,
      'created_at', v_account.created_at
    ),
    'session_token', v_session.token,
    'expires_at', v_session.expires_at
  );
end;
$$;
grant execute on function public.register_account(text, text, text) to anon, authenticated;

-- ============================================================
--  RPC: login_account
-- ============================================================
drop function if exists public.login_account(text, text);
create or replace function public.login_account(
  p_username text,
  p_pin text
)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_user text;
  v_account public.accounts;
  v_session public.account_sessions;
begin
  v_user := public.account_normalize_username(p_username);
  if not public.account_validate_pin(p_pin) then
    raise exception 'Falscher Benutzername oder PIN.';
  end if;

  select * into v_account from public.accounts where username = v_user;
  if not found then
    raise exception 'Falscher Benutzername oder PIN.';
  end if;

  if not public.account_verify_pin(p_pin, v_account.pin_hash) then
    raise exception 'Falscher Benutzername oder PIN.';
  end if;

  update public.accounts set last_login_at = now() where id = v_account.id;

  -- Abgelaufene Sessions des Accounts loeschen
  delete from public.account_sessions where account_id = v_account.id and expires_at < now();

  insert into public.account_sessions (account_id)
    values (v_account.id)
    returning * into v_session;

  return jsonb_build_object(
    'account', jsonb_build_object(
      'id', v_account.id,
      'username', v_account.username,
      'avatar_emoji', v_account.avatar_emoji,
      'created_at', v_account.created_at
    ),
    'session_token', v_session.token,
    'expires_at', v_session.expires_at
  );
end;
$$;
grant execute on function public.login_account(text, text) to anon, authenticated;

-- ============================================================
--  RPC: validate_session
--  Wird beim App-Start aufgerufen - prueft ob Token noch gueltig.
-- ============================================================
drop function if exists public.validate_session(uuid);
create or replace function public.validate_session(p_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_session public.account_sessions;
  v_account public.accounts;
begin
  select * into v_session from public.account_sessions where token = p_token;
  if not found then return null; end if;
  if v_session.expires_at < now() then
    delete from public.account_sessions where token = p_token;
    return null;
  end if;

  select * into v_account from public.accounts where id = v_session.account_id;
  if not found then return null; end if;

  return jsonb_build_object(
    'account', jsonb_build_object(
      'id', v_account.id,
      'username', v_account.username,
      'avatar_emoji', v_account.avatar_emoji,
      'created_at', v_account.created_at
    ),
    'expires_at', v_session.expires_at
  );
end;
$$;
grant execute on function public.validate_session(uuid) to anon, authenticated;

-- ============================================================
--  RPC: logout_account
-- ============================================================
drop function if exists public.logout_account(uuid);
create or replace function public.logout_account(p_token uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
begin
  delete from public.account_sessions where token = p_token;
  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.logout_account(uuid) to anon, authenticated;

-- ============================================================
--  RPC: update_avatar
-- ============================================================
drop function if exists public.update_avatar(uuid, text);
create or replace function public.update_avatar(p_token uuid, p_avatar text)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_session public.account_sessions;
  v_avatar text;
begin
  select * into v_session from public.account_sessions where token = p_token and expires_at > now();
  if not found then raise exception 'Sitzung abgelaufen. Bitte neu anmelden.'; end if;

  v_avatar := coalesce(nullif(trim(p_avatar), ''), '🦊');
  if char_length(v_avatar) > 8 then raise exception 'Avatar zu lang.'; end if;

  update public.accounts set avatar_emoji = v_avatar where id = v_session.account_id;

  return jsonb_build_object('ok', true, 'avatar_emoji', v_avatar);
end;
$$;
grant execute on function public.update_avatar(uuid, text) to anon, authenticated;

-- ============================================================
--  AKTUALISIERUNG: create_game / join_game mit optionalem Account
-- ============================================================
drop function if exists public.create_game(text, text, boolean, int);
create or replace function public.create_game(
  p_code text,
  p_guest_name text,
  p_timer_enabled boolean,
  p_turn_seconds int,
  p_session_token uuid default null
)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_game public.games;
  v_player public.game_players;
  v_clean_code text;
  v_clean_name text;
  v_seconds int;
  v_account_id uuid := null;
  v_account public.accounts;
  v_session public.account_sessions;
begin
  v_clean_code := upper(regexp_replace(coalesce(p_code, ''), '[^A-Z0-9]', '', 'g'));
  if length(v_clean_code) < 4 then raise exception 'Lobby-Code zu kurz.'; end if;
  v_clean_code := substr(v_clean_code, 1, 8);

  -- Account-Lookup wenn Token gegeben
  if p_session_token is not null then
    select * into v_session from public.account_sessions where token = p_session_token and expires_at > now();
    if found then
      select * into v_account from public.accounts where id = v_session.account_id;
      if found then
        v_account_id := v_account.id;
        v_clean_name := v_account.username;
      end if;
    end if;
  end if;

  -- Fallback: Gastname
  if v_clean_name is null then
    v_clean_name := nullif(trim(coalesce(p_guest_name, '')), '');
    if v_clean_name is null then v_clean_name := 'Host'; end if;
    if char_length(v_clean_name) > 24 then v_clean_name := substr(v_clean_name, 1, 24); end if;
  end if;

  v_seconds := coalesce(p_turn_seconds, 60);
  if v_seconds not in (10, 30, 60, 120) then v_seconds := 60; end if;

  insert into public.games (code, status, timer_enabled, turn_seconds, current_turn_order)
    values (v_clean_code, 'waiting', coalesce(p_timer_enabled, false), v_seconds, 1)
    returning * into v_game;

  insert into public.game_players (game_id, guest_name, turn_order, account_id)
    values (v_game.id, v_clean_name, 1, v_account_id)
    returning * into v_player;

  return jsonb_build_object(
    'game', to_jsonb(v_game) - 'host_secret',
    'player', to_jsonb(v_player) - 'player_secret',
    'host_secret', v_game.host_secret,
    'player_secret', v_player.player_secret
  );
end;
$$;
grant execute on function public.create_game(text, text, boolean, int, uuid) to anon, authenticated;

drop function if exists public.join_game(text, text);
create or replace function public.join_game(
  p_code text,
  p_guest_name text,
  p_session_token uuid default null
)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_game public.games;
  v_player public.game_players;
  v_clean_code text;
  v_clean_name text;
  v_next_order int;
  v_count int;
  v_account_id uuid := null;
  v_account public.accounts;
  v_session public.account_sessions;
  v_existing_player public.game_players;
begin
  v_clean_code := upper(regexp_replace(coalesce(p_code, ''), '[^A-Z0-9]', '', 'g'));
  v_clean_code := substr(v_clean_code, 1, 8);

  if p_session_token is not null then
    select * into v_session from public.account_sessions where token = p_session_token and expires_at > now();
    if found then
      select * into v_account from public.accounts where id = v_session.account_id;
      if found then
        v_account_id := v_account.id;
        v_clean_name := v_account.username;
      end if;
    end if;
  end if;

  if v_clean_name is null then
    v_clean_name := nullif(trim(coalesce(p_guest_name, '')), '');
    if v_clean_name is null then v_clean_name := 'Gast'; end if;
    if char_length(v_clean_name) > 24 then v_clean_name := substr(v_clean_name, 1, 24); end if;
  end if;

  select * into v_game from public.games where code = v_clean_code;
  if not found then raise exception 'Lobby wurde nicht gefunden.'; end if;
  if v_game.status <> 'waiting' then raise exception 'Diese Lobby spielt bereits oder ist beendet.'; end if;

  -- Wenn der Account schon in der Lobby ist: gleichen Spieler zurueckgeben
  if v_account_id is not null then
    select * into v_existing_player from public.game_players where game_id = v_game.id and account_id = v_account_id;
    if found then
      return jsonb_build_object(
        'game', to_jsonb(v_game) - 'host_secret',
        'player', to_jsonb(v_existing_player) - 'player_secret',
        'player_secret', v_existing_player.player_secret
      );
    end if;
  end if;

  select count(*) into v_count from public.game_players where game_id = v_game.id;
  if v_count >= v_game.max_players then raise exception 'Lobby ist voll.'; end if;

  select coalesce(max(turn_order), 0) + 1 into v_next_order
    from public.game_players where game_id = v_game.id;

  insert into public.game_players (game_id, guest_name, turn_order, account_id)
    values (v_game.id, v_clean_name, v_next_order, v_account_id)
    returning * into v_player;

  return jsonb_build_object(
    'game', to_jsonb(v_game) - 'host_secret',
    'player', to_jsonb(v_player) - 'player_secret',
    'player_secret', v_player.player_secret
  );
end;
$$;
grant execute on function public.join_game(text, text, uuid) to anon, authenticated;

-- ============================================================
--  AKTUALISIERUNG: game_players_public mit Account-Info
-- ============================================================
drop view if exists public.game_players_public cascade;
create view public.game_players_public as
  select
    gp.id, gp.game_id, gp.user_id, gp.guest_name, gp.turn_order,
    gp.is_eliminated, gp.eliminated_at, gp.joined_at,
    gp.account_id,
    a.username as account_username,
    a.avatar_emoji as account_avatar
  from public.game_players gp
  left join public.accounts a on a.id = gp.account_id;
grant select on public.game_players_public to anon, authenticated;
