-- sql/required_schema.sql
-- Supabase / PostgreSQL Schema für Animalchain
--
-- Lege diese Datei im Supabase SQL-Editor an und führe sie EINMAL aus.
-- Sie ist idempotent (kann mehrfach laufen).

create extension if not exists pgcrypto;
create extension if not exists unaccent;

-- ============================================================
--  HILFSFUNKTION: Tiernamen normalisieren
-- ============================================================
create or replace function public.normalize_animal_name(value text)
returns text
language sql
stable
as $$
  select trim(
    regexp_replace(
      regexp_replace(
        lower(unaccent(replace(coalesce(value, ''), 'ß', 'ss'))),
        '[^a-z\s-]',
        '',
        'g'
      ),
      '\s+',
      ' ',
      'g'
    )
  );
$$;

-- ============================================================
--  TABELLEN
-- ============================================================
create table if not exists public.animals (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  normalized_name text not null unique,
  first_letter text not null,
  last_letter text not null,
  language text not null default 'de',
  status text not null default 'approved',
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint animals_name_not_empty check (length(trim(name)) > 0),
  constraint animals_first_letter_one_char check (char_length(first_letter) = 1),
  constraint animals_last_letter_one_char check (char_length(last_letter) = 1),
  constraint animals_status_valid check (status in ('approved', 'pending', 'rejected'))
);

create table if not exists public.animal_suggestions (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  normalized_name text not null,
  first_letter text not null,
  last_letter text not null,
  suggested_by uuid references auth.users(id) on delete set null,
  status text not null default 'pending',
  created_at timestamptz not null default now(),
  constraint animal_suggestions_status_valid check (status in ('pending', 'approved', 'rejected'))
);

create table if not exists public.games (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  host_id uuid references auth.users(id) on delete cascade,
  host_secret uuid not null default gen_random_uuid(),
  current_player_id uuid references auth.users(id) on delete set null,
  current_required_letter text,
  current_turn_order int not null default 1,
  last_animal text not null default 'Turmfalke',
  status text not null default 'waiting',
  max_players int not null default 4,
  timer_enabled boolean not null default false,
  turn_seconds int not null default 60,
  turn_started_at timestamptz,
  created_at timestamptz not null default now(),
  constraint games_status_valid check (status in ('waiting', 'playing', 'finished')),
  constraint games_max_players_valid check (max_players between 2 and 8)
);

-- Spalten nachträglich hinzufügen, falls Tabelle aus älterer Migration existiert
alter table public.games add column if not exists host_id uuid references auth.users(id) on delete cascade;
alter table public.games add column if not exists host_secret uuid not null default gen_random_uuid();
alter table public.games add column if not exists current_player_id uuid references auth.users(id) on delete set null;
alter table public.games add column if not exists current_required_letter text;
alter table public.games add column if not exists current_turn_order int not null default 1;
alter table public.games add column if not exists last_animal text not null default 'Turmfalke';
alter table public.games add column if not exists status text not null default 'waiting';
alter table public.games add column if not exists max_players int not null default 4;
alter table public.games add column if not exists timer_enabled boolean not null default false;
alter table public.games add column if not exists turn_seconds int not null default 60;
alter table public.games add column if not exists turn_started_at timestamptz;

create table if not exists public.game_players (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games(id) on delete cascade,
  user_id uuid references auth.users(id) on delete cascade,
  guest_name text not null,
  player_secret uuid not null default gen_random_uuid(),
  turn_order int not null,
  is_eliminated boolean not null default false,
  eliminated_at timestamptz,
  joined_at timestamptz not null default now(),
  unique (game_id, turn_order)
);

alter table public.game_players add column if not exists user_id uuid references auth.users(id) on delete cascade;
alter table public.game_players add column if not exists player_secret uuid not null default gen_random_uuid();
alter table public.game_players add column if not exists is_eliminated boolean not null default false;
alter table public.game_players add column if not exists eliminated_at timestamptz;
alter table public.game_players add column if not exists joined_at timestamptz not null default now();

-- Wenn Spalten aus älterer Migration existieren, aber ohne Default,
-- ergänzen wir Default + NOT NULL nachträglich. Sonst schlägt INSERT fehl.
alter table public.games alter column host_secret set default gen_random_uuid();
update public.games set host_secret = gen_random_uuid() where host_secret is null;
alter table public.games alter column host_secret set not null;

alter table public.game_players alter column player_secret set default gen_random_uuid();
update public.game_players set player_secret = gen_random_uuid() where player_secret is null;
alter table public.game_players alter column player_secret set not null;

create table if not exists public.moves (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games(id) on delete cascade,
  player_id uuid references auth.users(id) on delete set null,
  game_player_id uuid references public.game_players(id) on delete set null,
  animal_id uuid references public.animals(id) on delete set null,
  animal_name text not null,
  normalized_animal_name text not null,
  guest_name text,
  required_letter text not null,
  next_required_letter text not null,
  move_number int not null,
  created_at timestamptz not null default now(),
  unique (game_id, normalized_animal_name),
  unique (game_id, move_number)
);

-- Moves-Spalten ergänzen, falls Tabelle aus älterer Migration existiert
alter table public.moves add column if not exists player_id uuid references auth.users(id) on delete set null;
alter table public.moves add column if not exists game_player_id uuid references public.game_players(id) on delete set null;
alter table public.moves add column if not exists animal_id uuid references public.animals(id) on delete set null;
alter table public.moves add column if not exists guest_name text;
alter table public.moves add column if not exists required_letter text;
alter table public.moves add column if not exists next_required_letter text;
alter table public.moves add column if not exists move_number int;

-- ============================================================
--  INDEXE
-- ============================================================
create index if not exists animals_first_letter_idx on public.animals(first_letter);
create index if not exists animals_normalized_name_idx on public.animals(normalized_name);
create index if not exists games_code_idx on public.games(code);
create index if not exists moves_game_id_idx on public.moves(game_id);
create index if not exists game_players_game_id_idx on public.game_players(game_id);

-- ============================================================
--  VIEWS — verbergen host_secret/player_secret vor anon
-- ============================================================
drop view if exists public.games_public cascade;
create view public.games_public as
  select
    id, code, host_id, current_player_id, current_required_letter,
    current_turn_order, last_animal, status, max_players,
    timer_enabled, turn_seconds, turn_started_at, created_at
  from public.games;

drop view if exists public.game_players_public cascade;
create view public.game_players_public as
  select
    id, game_id, user_id, guest_name, turn_order,
    is_eliminated, eliminated_at, joined_at
  from public.game_players;

grant select on public.games_public to anon, authenticated;
grant select on public.game_players_public to anon, authenticated;

-- ============================================================
--  ROW-LEVEL SECURITY
-- ============================================================
alter table public.animals enable row level security;
alter table public.animal_suggestions enable row level security;
alter table public.games enable row level security;
alter table public.game_players enable row level security;
alter table public.moves enable row level security;

drop policy if exists "animals_select_all" on public.animals;
drop policy if exists "animal_suggestions_select_all" on public.animal_suggestions;
drop policy if exists "animal_suggestions_insert_all" on public.animal_suggestions;
drop policy if exists "games_select_all" on public.games;
drop policy if exists "games_insert_all" on public.games;
drop policy if exists "games_update_all" on public.games;
drop policy if exists "game_players_select_all" on public.game_players;
drop policy if exists "game_players_insert_all" on public.game_players;
drop policy if exists "game_players_update_all" on public.game_players;
drop policy if exists "game_players_delete_all" on public.game_players;
drop policy if exists "moves_select_all" on public.moves;
drop policy if exists "moves_insert_all" on public.moves;

-- Lesen: alle dürfen alles lesen (Spiele sind öffentlich per Code)
-- Schreiben: NUR über die SECURITY-DEFINER RPC-Funktionen unten.
-- Direkter INSERT/UPDATE auf games/game_players/moves wird verweigert.
create policy "animals_select_all" on public.animals for select to anon, authenticated using (true);
create policy "animal_suggestions_select_all" on public.animal_suggestions for select to anon, authenticated using (true);
create policy "animal_suggestions_insert_all" on public.animal_suggestions for insert to anon, authenticated with check (true);
create policy "games_select_all" on public.games for select to anon, authenticated using (true);
create policy "game_players_select_all" on public.game_players for select to anon, authenticated using (true);
create policy "moves_select_all" on public.moves for select to anon, authenticated using (true);

-- ============================================================
--  RPC-FUNKTIONEN
-- ============================================================

-- create_game ---------------------------------------------------
drop function if exists public.create_game(text, text, boolean, int);
create or replace function public.create_game(
  p_code text,
  p_guest_name text,
  p_timer_enabled boolean,
  p_turn_seconds int
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_game public.games;
  v_player public.game_players;
  v_clean_code text;
  v_clean_name text;
  v_seconds int;
begin
  v_clean_code := upper(regexp_replace(coalesce(p_code, ''), '[^A-Z0-9]', '', 'g'));
  if length(v_clean_code) < 4 then
    raise exception 'Lobby-Code zu kurz.';
  end if;
  v_clean_code := substr(v_clean_code, 1, 8);

  v_clean_name := nullif(trim(coalesce(p_guest_name, '')), '');
  if v_clean_name is null then v_clean_name := 'Host'; end if;
  if char_length(v_clean_name) > 24 then v_clean_name := substr(v_clean_name, 1, 24); end if;

  v_seconds := coalesce(p_turn_seconds, 60);
  if v_seconds not in (10, 30, 60, 120) then v_seconds := 60; end if;

  insert into public.games (code, status, timer_enabled, turn_seconds, current_turn_order)
    values (v_clean_code, 'waiting', coalesce(p_timer_enabled, false), v_seconds, 1)
    returning * into v_game;

  insert into public.game_players (game_id, guest_name, turn_order)
    values (v_game.id, v_clean_name, 1)
    returning * into v_player;

  return jsonb_build_object(
    'game', to_jsonb(v_game) - 'host_secret',
    'player', to_jsonb(v_player) - 'player_secret',
    'host_secret', v_game.host_secret,
    'player_secret', v_player.player_secret
  );
end;
$$;
grant execute on function public.create_game(text, text, boolean, int) to anon, authenticated;

-- join_game ---------------------------------------------------
drop function if exists public.join_game(text, text);
create or replace function public.join_game(
  p_code text,
  p_guest_name text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_game public.games;
  v_player public.game_players;
  v_clean_code text;
  v_clean_name text;
  v_next_order int;
  v_count int;
begin
  v_clean_code := upper(regexp_replace(coalesce(p_code, ''), '[^A-Z0-9]', '', 'g'));
  v_clean_code := substr(v_clean_code, 1, 8);

  v_clean_name := nullif(trim(coalesce(p_guest_name, '')), '');
  if v_clean_name is null then v_clean_name := 'Gast'; end if;
  if char_length(v_clean_name) > 24 then v_clean_name := substr(v_clean_name, 1, 24); end if;

  select * into v_game from public.games where code = v_clean_code;
  if not found then raise exception 'Lobby wurde nicht gefunden.'; end if;
  if v_game.status <> 'waiting' then raise exception 'Diese Lobby spielt bereits oder ist beendet.'; end if;

  select count(*) into v_count from public.game_players where game_id = v_game.id;
  if v_count >= v_game.max_players then raise exception 'Lobby ist voll.'; end if;

  select coalesce(max(turn_order), 0) + 1 into v_next_order
    from public.game_players where game_id = v_game.id;

  insert into public.game_players (game_id, guest_name, turn_order)
    values (v_game.id, v_clean_name, v_next_order)
    returning * into v_player;

  return jsonb_build_object(
    'game', to_jsonb(v_game) - 'host_secret',
    'player', to_jsonb(v_player) - 'player_secret',
    'player_secret', v_player.player_secret
  );
end;
$$;
grant execute on function public.join_game(text, text) to anon, authenticated;

-- start_game ---------------------------------------------------
drop function if exists public.start_game(uuid, uuid, text);
create or replace function public.start_game(
  p_game_id uuid,
  p_host_secret uuid,
  p_animal_name text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_game public.games;
  v_first_letter text;
  v_last_letter text;
  v_player_count int;
begin
  select * into v_game from public.games where id = p_game_id;
  if not found then raise exception 'Lobby nicht gefunden.'; end if;
  if v_game.host_secret <> p_host_secret then raise exception 'Nur der Host darf starten.'; end if;

  select count(*) into v_player_count from public.game_players where game_id = p_game_id;
  if v_player_count < 2 then raise exception 'Mindestens 2 Spieler erforderlich.'; end if;

  v_first_letter := substr(public.normalize_animal_name(p_animal_name), 1, 1);
  v_last_letter := substr(regexp_replace(public.normalize_animal_name(p_animal_name), '[^a-z]', '', 'g'),
                          length(regexp_replace(public.normalize_animal_name(p_animal_name), '[^a-z]', '', 'g')),
                          1);

  -- Vorherige Züge dieser Runde löschen, Spieler reaktivieren
  delete from public.moves where game_id = p_game_id;
  update public.game_players
     set is_eliminated = false, eliminated_at = null
   where game_id = p_game_id;

  update public.games
     set status = 'playing',
         last_animal = p_animal_name,
         current_required_letter = v_last_letter,
         current_turn_order = 1,
         turn_started_at = now()
   where id = p_game_id
   returning * into v_game;

  return to_jsonb(v_game) - 'host_secret';
end;
$$;
grant execute on function public.start_game(uuid, uuid, text) to anon, authenticated;

-- make_move ---------------------------------------------------
drop function if exists public.make_move(uuid, uuid, uuid, text);
create or replace function public.make_move(
  p_game_id uuid,
  p_player_id uuid,
  p_player_secret uuid,
  p_animal_name text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_game public.games;
  v_player public.game_players;
  v_norm text;
  v_first text;
  v_last text;
  v_existing int;
  v_next_order int;
  v_move_number int;
  v_animal public.animals;
begin
  select * into v_game from public.games where id = p_game_id;
  if not found then raise exception 'Lobby nicht gefunden.'; end if;
  if v_game.status <> 'playing' then raise exception 'Spiel läuft nicht.'; end if;

  select * into v_player from public.game_players where id = p_player_id and game_id = p_game_id;
  if not found then raise exception 'Spieler nicht gefunden.'; end if;
  if v_player.player_secret <> p_player_secret then raise exception 'Falsches Spieler-Token.'; end if;
  if v_player.is_eliminated then raise exception 'Du bist ausgeschieden.'; end if;
  if v_player.turn_order <> v_game.current_turn_order then raise exception 'Du bist nicht dran.'; end if;

  v_norm := public.normalize_animal_name(p_animal_name);
  if char_length(v_norm) < 2 then raise exception 'Tiername zu kurz.'; end if;

  v_first := substr(regexp_replace(v_norm, '[^a-z]', '', 'g'), 1, 1);
  v_last := substr(regexp_replace(v_norm, '[^a-z]', '', 'g'),
                   length(regexp_replace(v_norm, '[^a-z]', '', 'g')), 1);

  if v_first <> v_game.current_required_letter then
    raise exception 'Dein Tier muss mit % anfangen.', upper(v_game.current_required_letter);
  end if;

  -- bereits gespielt?
  select count(*) into v_existing from public.moves
    where game_id = p_game_id and normalized_animal_name = v_norm;
  if v_existing > 0 then raise exception 'Dieses Tier wurde schon gespielt.'; end if;

  -- existiert das Tier in der Datenbank?
  select * into v_animal from public.animals
    where normalized_name = v_norm and status = 'approved' limit 1;
  if not found then raise exception '"%" ist nicht in der Tierliste.', p_animal_name; end if;

  -- nächste move_number
  select coalesce(max(move_number), 0) + 1 into v_move_number from public.moves where game_id = p_game_id;

  insert into public.moves (
    game_id, game_player_id, animal_id, animal_name, normalized_animal_name,
    guest_name, required_letter, next_required_letter, move_number
  ) values (
    p_game_id, p_player_id, v_animal.id, v_animal.name, v_norm,
    v_player.guest_name, v_game.current_required_letter, v_last, v_move_number
  );

  -- nächsten aktiven Spieler bestimmen (kreisförmig, übersprung der eliminierten)
  v_next_order := v_game.current_turn_order;
  for i in 1..16 loop
    v_next_order := v_next_order + 1;
    if v_next_order > (select max(turn_order) from public.game_players where game_id = p_game_id) then
      v_next_order := 1;
    end if;
    exit when exists (
      select 1 from public.game_players
       where game_id = p_game_id and turn_order = v_next_order and is_eliminated = false
    );
  end loop;

  update public.games
     set last_animal = v_animal.name,
         current_required_letter = v_last,
         current_turn_order = v_next_order,
         turn_started_at = now()
   where id = p_game_id
   returning * into v_game;

  return to_jsonb(v_game) - 'host_secret';
end;
$$;
grant execute on function public.make_move(uuid, uuid, uuid, text) to anon, authenticated;

-- kick_player ---------------------------------------------------
drop function if exists public.kick_player(uuid, uuid, uuid);
create or replace function public.kick_player(
  p_game_id uuid,
  p_host_secret uuid,
  p_player_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_game public.games;
begin
  select * into v_game from public.games where id = p_game_id;
  if not found then raise exception 'Lobby nicht gefunden.'; end if;
  if v_game.host_secret <> p_host_secret then raise exception 'Nur der Host darf kicken.'; end if;
  if v_game.status <> 'waiting' then raise exception 'Kicken nur im Warteraum möglich.'; end if;

  delete from public.game_players where id = p_player_id and game_id = p_game_id;

  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.kick_player(uuid, uuid, uuid) to anon, authenticated;

-- self_eliminate ---------------------------------------------------
drop function if exists public.self_eliminate(uuid, uuid, uuid);
create or replace function public.self_eliminate(
  p_game_id uuid,
  p_player_id uuid,
  p_player_secret uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_game public.games;
  v_player public.game_players;
  v_next_order int;
  v_active_count int;
begin
  select * into v_game from public.games where id = p_game_id;
  if not found then raise exception 'Lobby nicht gefunden.'; end if;

  select * into v_player from public.game_players where id = p_player_id and game_id = p_game_id;
  if not found then raise exception 'Spieler nicht gefunden.'; end if;
  if v_player.player_secret <> p_player_secret then raise exception 'Falsches Spieler-Token.'; end if;

  update public.game_players
     set is_eliminated = true, eliminated_at = now()
   where id = p_player_id;

  -- Falls aktueller Spieler ausgeschieden: weitergeben
  if v_game.status = 'playing' and v_player.turn_order = v_game.current_turn_order then
    v_next_order := v_game.current_turn_order;
    for i in 1..16 loop
      v_next_order := v_next_order + 1;
      if v_next_order > (select max(turn_order) from public.game_players where game_id = p_game_id) then
        v_next_order := 1;
      end if;
      exit when exists (
        select 1 from public.game_players
         where game_id = p_game_id and turn_order = v_next_order and is_eliminated = false
      );
    end loop;
    update public.games
       set current_turn_order = v_next_order, turn_started_at = now()
     where id = p_game_id;
  end if;

  -- Falls nur noch ein aktiver Spieler übrig: Spiel beenden
  select count(*) into v_active_count from public.game_players
    where game_id = p_game_id and is_eliminated = false;
  if v_active_count <= 1 then
    update public.games set status = 'finished' where id = p_game_id;
  end if;

  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.self_eliminate(uuid, uuid, uuid) to anon, authenticated;

-- leave_lobby ---------------------------------------------------
drop function if exists public.leave_lobby(uuid, uuid, uuid);
create or replace function public.leave_lobby(
  p_game_id uuid,
  p_player_id uuid,
  p_player_secret uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_game public.games;
  v_player public.game_players;
  v_remaining int;
begin
  select * into v_game from public.games where id = p_game_id;
  if not found then raise exception 'Lobby nicht gefunden.'; end if;

  select * into v_player from public.game_players where id = p_player_id and game_id = p_game_id;
  if not found then raise exception 'Spieler nicht gefunden.'; end if;
  if v_player.player_secret <> p_player_secret then raise exception 'Falsches Spieler-Token.'; end if;

  if v_game.status = 'waiting' then
    delete from public.game_players where id = p_player_id;
  else
    update public.game_players
       set is_eliminated = true, eliminated_at = now()
     where id = p_player_id;
  end if;

  -- Wenn niemand mehr übrig: Lobby löschen
  select count(*) into v_remaining from public.game_players where game_id = p_game_id;
  if v_remaining = 0 then
    delete from public.games where id = p_game_id;
  end if;

  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.leave_lobby(uuid, uuid, uuid) to anon, authenticated;

-- ============================================================
--  STARTTIERE
-- ============================================================
insert into public.animals (name, normalized_name, first_letter, last_letter, language, status)
values
  ('Ameise', 'ameise', 'a', 'e', 'de', 'approved'),
  ('Echse', 'echse', 'e', 'e', 'de', 'approved'),
  ('Esel', 'esel', 'e', 'l', 'de', 'approved'),
  ('Ente', 'ente', 'e', 'e', 'de', 'approved'),
  ('Elefant', 'elefant', 'e', 't', 'de', 'approved'),
  ('Turmfalke', 'turmfalke', 't', 'e', 'de', 'approved'),
  ('Hase', 'hase', 'h', 'e', 'de', 'approved'),
  ('Roter Panda', 'roter panda', 'r', 'a', 'de', 'approved'),
  ('Adler', 'adler', 'a', 'r', 'de', 'approved'),
  ('Reh', 'reh', 'r', 'h', 'de', 'approved'),
  ('Hund', 'hund', 'h', 'd', 'de', 'approved'),
  ('Delfin', 'delfin', 'd', 'n', 'de', 'approved'),
  ('Nashorn', 'nashorn', 'n', 'n', 'de', 'approved'),
  ('Tiger', 'tiger', 't', 'r', 'de', 'approved'),
  ('Löwe', 'lowe', 'l', 'e', 'de', 'approved'),
  ('Pinguin', 'pinguin', 'p', 'n', 'de', 'approved'),
  ('Eichhörnchen', 'eichhornchen', 'e', 'n', 'de', 'approved'),
  ('Wolf', 'wolf', 'w', 'f', 'de', 'approved'),
  ('Fuchs', 'fuchs', 'f', 's', 'de', 'approved'),
  ('Schaf', 'schaf', 's', 'f', 'de', 'approved')
on conflict (normalized_name) do update
set name = excluded.name,
    first_letter = excluded.first_letter,
    last_letter = excluded.last_letter,
    language = excluded.language,
    status = excluded.status;
