-- sql/required_schema.sql
-- Supabase / PostgreSQL Schema für Animalchain

create extension if not exists pgcrypto;
create extension if not exists unaccent;

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

create table if not exists public.game_players (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games(id) on delete cascade,
  user_id uuid references auth.users(id) on delete cascade,
  guest_name text not null,
  turn_order int not null,
  is_eliminated boolean not null default false,
  eliminated_at timestamptz,
  joined_at timestamptz not null default now(),
  unique (game_id, turn_order)
);

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

alter table public.games add column if not exists timer_enabled boolean not null default false;
alter table public.games add column if not exists turn_seconds int not null default 60;
alter table public.games add column if not exists turn_started_at timestamptz;
alter table public.game_players add column if not exists is_eliminated boolean not null default false;
alter table public.game_players add column if not exists eliminated_at timestamptz;

create index if not exists animals_first_letter_idx on public.animals(first_letter);
create index if not exists animals_normalized_name_idx on public.animals(normalized_name);
create index if not exists games_code_idx on public.games(code);
create index if not exists moves_game_id_idx on public.moves(game_id);
create index if not exists game_players_game_id_idx on public.game_players(game_id);

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
drop policy if exists "moves_select_all" on public.moves;
drop policy if exists "moves_insert_all" on public.moves;

create policy "animals_select_all" on public.animals for select to anon, authenticated using (true);
create policy "animal_suggestions_select_all" on public.animal_suggestions for select to anon, authenticated using (true);
create policy "animal_suggestions_insert_all" on public.animal_suggestions for insert to anon, authenticated with check (true);
create policy "games_select_all" on public.games for select to anon, authenticated using (true);
create policy "games_insert_all" on public.games for insert to anon, authenticated with check (true);
create policy "games_update_all" on public.games for update to anon, authenticated using (true) with check (true);
create policy "game_players_select_all" on public.game_players for select to anon, authenticated using (true);
create policy "game_players_insert_all" on public.game_players for insert to anon, authenticated with check (true);
create policy "game_players_update_all" on public.game_players for update to anon, authenticated using (true) with check (true);
create policy "moves_select_all" on public.moves for select to anon, authenticated using (true);
create policy "moves_insert_all" on public.moves for insert to anon, authenticated with check (true);

insert into public.animals (name, normalized_name, first_letter, last_letter, language, status)
values
  ('Ameise', 'ameise', 'a', 'e', 'de', 'approved'),
  ('Echse', 'echse', 'e', 'e', 'de', 'approved'),
  ('Esel', 'esel', 'e', 'l', 'de', 'approved'),
  ('Ente', 'ente', 'e', 'e', 'de', 'approved'),
  ('Elefant', 'elefant', 'e', 't', 'de', 'approved'),
  ('Turmfalke', 'turmfalke', 't', 'e', 'de', 'approved'),
  ('Hase', 'hase', 'h', 'e', 'de', 'approved'),
  ('Roter Panda', 'roter panda', 'r', 'a', 'de', 'approved')
on conflict (normalized_name) do update
set name = excluded.name,
    first_letter = excluded.first_letter,
    last_letter = excluded.last_letter,
    language = excluded.language,
    status = excluded.status;