-- 20260529000000_xp_admin_suggestions.sql
-- XP-System, Admin-Rolle, erweiterte Tiervorschlag-Workflow.
-- Idempotent: kann mehrfach ausgeführt werden.

create extension if not exists pgcrypto;

-- ============================================================
--  1) accounts: is_admin Flag
-- ============================================================
alter table public.accounts
  add column if not exists is_admin boolean not null default false;

-- ============================================================
--  2) user_stats: Statistik pro Account
-- ============================================================
create table if not exists public.user_stats (
  account_id uuid primary key references public.accounts(id) on delete cascade,
  total_xp int not null default 0,
  level int not null default 1,
  games_played int not null default 0,
  games_won int not null default 0,
  current_streak int not null default 0,
  best_streak int not null default 0,
  longest_chain int not null default 0,
  approved_suggestions int not null default 0,
  daily_xp_today int not null default 0,
  daily_xp_date date not null default current_date,
  updated_at timestamptz not null default now()
);

create index if not exists user_stats_total_xp_idx on public.user_stats(total_xp desc);

-- ============================================================
--  3) xp_log: Audit-Trail
-- ============================================================
create table if not exists public.xp_log (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  amount int not null,
  reason text not null,
  game_id uuid references public.games(id) on delete set null,
  metadata jsonb,
  created_at timestamptz not null default now()
);

create index if not exists xp_log_account_idx on public.xp_log(account_id, created_at desc);
-- Idempotenz für game_finish: pro (account, spiel) nur einmal
create unique index if not exists xp_log_game_finish_uq
  on public.xp_log(account_id, game_id)
  where reason = 'game_finish' and game_id is not null;

-- ============================================================
--  4) animal_suggestions: Spalten ergänzen
-- ============================================================
alter table public.animal_suggestions
  add column if not exists category text,
  add column if not exists source text,
  add column if not exists suggested_by_account_id uuid references public.accounts(id) on delete set null,
  add column if not exists reviewed_by_account_id uuid references public.accounts(id) on delete set null,
  add column if not exists review_reason text,
  add column if not exists reviewed_at timestamptz;

-- Kategorie-Constraint (nur wenn gesetzt)
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'animal_suggestions_category_valid'
  ) then
    alter table public.animal_suggestions
      add constraint animal_suggestions_category_valid
      check (category is null or category in ('saeugetier','vogel','fisch','reptil','amphibie','insekt','sonstiges'));
  end if;
end $$;

create index if not exists animal_suggestions_status_idx on public.animal_suggestions(status, created_at desc);
create index if not exists animal_suggestions_account_idx on public.animal_suggestions(suggested_by_account_id, created_at desc);

-- ============================================================
--  5) RLS — neue Tabellen
-- ============================================================
alter table public.user_stats enable row level security;
alter table public.xp_log enable row level security;

drop policy if exists "user_stats_select_all" on public.user_stats;
create policy "user_stats_select_all" on public.user_stats for select to anon, authenticated using (true);

-- xp_log: kein direkter Lesezugriff für anon, nur via RPC. Keine SELECT-Policy = zu.

-- ============================================================
--  6) Level-Berechnung
--  Level n → n+1 braucht 100 × n XP.
--  Kumulativ bei Level n: 50 * n * (n-1).
--  Daher n = floor((1 + sqrt(1 + 4*xp/50)) / 2).
-- ============================================================
create or replace function public.compute_level(p_xp int)
returns int language sql immutable as $$
  select greatest(1,
    floor((1 + sqrt(1 + (4.0 * greatest(coalesce(p_xp,0),0) / 50.0))) / 2)::int
  );
$$;

-- ============================================================
--  7) interne XP-Vergabe
-- ============================================================
create or replace function public.internal_award_xp(
  p_account_id uuid,
  p_amount int,
  p_reason text,
  p_metadata jsonb default null,
  p_game_id uuid default null,
  p_respect_daily_cap boolean default true
)
returns int language plpgsql security definer set search_path = public
as $$
declare
  v_stats public.user_stats;
  v_remaining_cap int;
  v_credited int;
begin
  if p_amount is null or p_amount <= 0 then return 0; end if;

  insert into public.user_stats (account_id) values (p_account_id)
    on conflict (account_id) do nothing;

  update public.user_stats
    set daily_xp_today = 0, daily_xp_date = current_date
    where account_id = p_account_id and daily_xp_date <> current_date;

  select * into v_stats from public.user_stats where account_id = p_account_id;

  v_credited := p_amount;
  if p_respect_daily_cap then
    v_remaining_cap := greatest(0, 300 - v_stats.daily_xp_today);
    v_credited := least(p_amount, v_remaining_cap);
  end if;
  if v_credited <= 0 then return 0; end if;

  update public.user_stats
    set total_xp = total_xp + v_credited,
        daily_xp_today = case when p_respect_daily_cap
          then daily_xp_today + v_credited else daily_xp_today end,
        level = public.compute_level(total_xp + v_credited),
        updated_at = now()
    where account_id = p_account_id;

  insert into public.xp_log (account_id, amount, reason, metadata, game_id)
    values (p_account_id, v_credited, p_reason, p_metadata, p_game_id);

  return v_credited;
end;
$$;

-- ============================================================
--  8) RPC: get_my_stats
-- ============================================================
drop function if exists public.get_my_stats(uuid);
create or replace function public.get_my_stats(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_session public.account_sessions;
  v_account public.accounts;
  v_stats public.user_stats;
  v_xp_curr int;
  v_xp_next int;
  v_recent jsonb;
  v_top_animals jsonb;
  v_pending_suggestions int;
begin
  select * into v_session from public.account_sessions
    where token = p_session_token and expires_at > now();
  if not found then raise exception 'Bitte anmelden.'; end if;
  select * into v_account from public.accounts where id = v_session.account_id;

  insert into public.user_stats (account_id) values (v_account.id) on conflict do nothing;
  select * into v_stats from public.user_stats where account_id = v_account.id;

  v_xp_curr := 50 * v_stats.level * (v_stats.level - 1);
  v_xp_next := 50 * (v_stats.level + 1) * v_stats.level;

  -- Daily-Reset bei Lesezugriff
  if v_stats.daily_xp_date <> current_date then
    update public.user_stats set daily_xp_today = 0, daily_xp_date = current_date
      where account_id = v_account.id;
    v_stats.daily_xp_today := 0;
  end if;

  -- Top-5 Tiere
  select coalesce(jsonb_agg(jsonb_build_object('name', t.name, 'count', t.cnt) order by t.cnt desc), '[]'::jsonb)
  into v_top_animals
  from (
    select m.animal_name as name, count(*) as cnt
    from public.moves m
    join public.game_players gp on gp.id = m.game_player_id
    where gp.account_id = v_account.id
    group by m.animal_name
    order by cnt desc
    limit 5
  ) t;

  -- Letzte 10 Spiele (aus xp_log)
  select coalesce(jsonb_agg(jsonb_build_object(
    'game_id', x.game_id, 'finished_at', x.finished_at,
    'is_winner', x.is_winner, 'chain_length', x.chain_length,
    'xp_awarded', x.xp_awarded
  ) order by x.finished_at desc), '[]'::jsonb) into v_recent
  from (
    select
      l.game_id, l.created_at as finished_at,
      (l.metadata->>'is_winner')::boolean as is_winner,
      coalesce((l.metadata->>'chain_length')::int, 0) as chain_length,
      l.amount as xp_awarded
    from public.xp_log l
    where l.account_id = v_account.id
      and l.reason = 'game_finish'
      and l.game_id is not null
    order by l.created_at desc
    limit 10
  ) x;

  select count(*) into v_pending_suggestions
    from public.animal_suggestions
    where status = 'pending';

  return jsonb_build_object(
    'username', v_account.username,
    'avatar_emoji', v_account.avatar_emoji,
    'is_admin', v_account.is_admin,
    'total_xp', v_stats.total_xp,
    'level', v_stats.level,
    'xp_in_level', v_stats.total_xp - v_xp_curr,
    'xp_for_next_level', v_xp_next - v_xp_curr,
    'games_played', v_stats.games_played,
    'games_won', v_stats.games_won,
    'win_rate', case when v_stats.games_played > 0
      then round(v_stats.games_won::numeric / v_stats.games_played * 100, 0) else 0 end,
    'current_streak', v_stats.current_streak,
    'best_streak', v_stats.best_streak,
    'longest_chain', v_stats.longest_chain,
    'approved_suggestions', v_stats.approved_suggestions,
    'daily_xp_today', v_stats.daily_xp_today,
    'daily_xp_cap', 300,
    'top_animals', v_top_animals,
    'recent_games', v_recent,
    'pending_admin_count', case when v_account.is_admin then v_pending_suggestions else 0 end
  );
end;
$$;
grant execute on function public.get_my_stats(uuid) to anon, authenticated;

-- ============================================================
--  9) RPC: submit_animal_suggestion
-- ============================================================
drop function if exists public.submit_animal_suggestion(uuid, text, text, text);
create or replace function public.submit_animal_suggestion(
  p_session_token uuid,
  p_name text,
  p_category text,
  p_source text default null
)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_session public.account_sessions;
  v_account public.accounts;
  v_norm text;
  v_letters text;
  v_first text;
  v_last text;
  v_existing public.animals;
  v_dup_pending int;
  v_suggestion public.animal_suggestions;
begin
  select * into v_session from public.account_sessions
    where token = p_session_token and expires_at > now();
  if not found then raise exception 'Bitte anmelden.'; end if;
  select * into v_account from public.accounts where id = v_session.account_id;

  if length(coalesce(trim(p_name), '')) < 2 then raise exception 'Tiername zu kurz.'; end if;
  if length(coalesce(trim(p_name), '')) > 40 then raise exception 'Tiername zu lang (max 40 Zeichen).'; end if;

  if p_category is null or p_category not in
       ('saeugetier','vogel','fisch','reptil','amphibie','insekt','sonstiges') then
    raise exception 'Bitte gültige Kategorie wählen.';
  end if;

  v_norm := public.normalize_animal_name(p_name);
  v_letters := regexp_replace(v_norm, '[^a-z]', '', 'g');
  if char_length(v_letters) < 2 then
    raise exception 'Tiername muss mindestens 2 Buchstaben enthalten.';
  end if;
  v_first := substr(v_letters, 1, 1);
  v_last := substr(v_letters, char_length(v_letters), 1);

  select * into v_existing from public.animals
    where normalized_name = v_norm and status = 'approved' limit 1;
  if found then raise exception '"%" existiert bereits in der Datenbank.', v_existing.name; end if;

  select count(*) into v_dup_pending from public.animal_suggestions
    where normalized_name = v_norm and status = 'pending';
  if v_dup_pending > 0 then
    raise exception '"%" wurde bereits vorgeschlagen und wartet auf Prüfung.', trim(p_name);
  end if;

  insert into public.animal_suggestions (
    name, normalized_name, first_letter, last_letter,
    category, source, suggested_by_account_id, status
  ) values (
    trim(p_name), v_norm, v_first, v_last,
    p_category, nullif(trim(coalesce(p_source,'')), ''), v_account.id, 'pending'
  ) returning * into v_suggestion;

  return to_jsonb(v_suggestion);
end;
$$;
grant execute on function public.submit_animal_suggestion(uuid, text, text, text) to anon, authenticated;

-- ============================================================
--  10) RPC: list_my_suggestions
-- ============================================================
drop function if exists public.list_my_suggestions(uuid);
create or replace function public.list_my_suggestions(p_session_token uuid)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_session public.account_sessions;
  v_result jsonb;
begin
  select * into v_session from public.account_sessions
    where token = p_session_token and expires_at > now();
  if not found then raise exception 'Bitte anmelden.'; end if;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', s.id, 'name', s.name, 'category', s.category, 'source', s.source,
      'status', s.status, 'review_reason', s.review_reason,
      'reviewed_at', s.reviewed_at, 'created_at', s.created_at
    ) order by s.created_at desc
  ), '[]'::jsonb) into v_result
  from public.animal_suggestions s
  where s.suggested_by_account_id = v_session.account_id;

  return v_result;
end;
$$;
grant execute on function public.list_my_suggestions(uuid) to anon, authenticated;

-- ============================================================
--  11) RPC: admin_list_suggestions
-- ============================================================
drop function if exists public.admin_list_suggestions(uuid, text);
create or replace function public.admin_list_suggestions(
  p_session_token uuid,
  p_status text default 'pending'
)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_session public.account_sessions;
  v_account public.accounts;
  v_result jsonb;
begin
  select * into v_session from public.account_sessions
    where token = p_session_token and expires_at > now();
  if not found then raise exception 'Bitte anmelden.'; end if;
  select * into v_account from public.accounts where id = v_session.account_id;
  if not coalesce(v_account.is_admin, false) then raise exception 'Nur Admins dürfen das.'; end if;

  if p_status is null or p_status not in ('pending','approved','rejected','all') then
    p_status := 'pending';
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', sg.id, 'name', sg.name, 'normalized_name', sg.normalized_name,
      'category', sg.category, 'source', sg.source, 'status', sg.status,
      'review_reason', sg.review_reason, 'reviewed_at', sg.reviewed_at,
      'created_at', sg.created_at,
      'suggested_by_username', a.username,
      'suggested_by_avatar', a.avatar_emoji
    ) order by sg.created_at desc
  ), '[]'::jsonb)
  into v_result
  from public.animal_suggestions sg
  left join public.accounts a on a.id = sg.suggested_by_account_id
  where (p_status = 'all' or sg.status = p_status);

  return v_result;
end;
$$;
grant execute on function public.admin_list_suggestions(uuid, text) to anon, authenticated;

-- ============================================================
--  12) RPC: approve_animal_suggestion
-- ============================================================
drop function if exists public.approve_animal_suggestion(uuid, uuid);
create or replace function public.approve_animal_suggestion(
  p_session_token uuid,
  p_suggestion_id uuid
)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_session public.account_sessions;
  v_account public.accounts;
  v_suggestion public.animal_suggestions;
  v_animal public.animals;
  v_count int;
  v_xp_amount int;
  v_xp_reason text;
begin
  select * into v_session from public.account_sessions
    where token = p_session_token and expires_at > now();
  if not found then raise exception 'Bitte anmelden.'; end if;
  select * into v_account from public.accounts where id = v_session.account_id;
  if not coalesce(v_account.is_admin, false) then raise exception 'Nur Admins dürfen genehmigen.'; end if;

  select * into v_suggestion from public.animal_suggestions where id = p_suggestion_id;
  if not found then raise exception 'Vorschlag nicht gefunden.'; end if;
  if v_suggestion.status <> 'pending' then
    raise exception 'Vorschlag wurde bereits bearbeitet.';
  end if;

  -- Duplikat-Check
  select * into v_animal from public.animals
    where normalized_name = v_suggestion.normalized_name limit 1;
  if found then
    update public.animal_suggestions
       set status = 'rejected',
           review_reason = 'Existiert bereits in der Datenbank',
           reviewed_by_account_id = v_account.id,
           reviewed_at = now()
     where id = p_suggestion_id;
    raise exception '"%" existiert bereits in der Datenbank.', v_animal.name;
  end if;

  insert into public.animals
    (name, normalized_name, first_letter, last_letter, language, status, created_by)
    values
    (v_suggestion.name, v_suggestion.normalized_name,
     v_suggestion.first_letter, v_suggestion.last_letter,
     'de', 'approved', null)
    returning * into v_animal;

  update public.animal_suggestions
     set status = 'approved',
         reviewed_by_account_id = v_account.id,
         reviewed_at = now()
   where id = p_suggestion_id;

  -- XP für Einreicher
  if v_suggestion.suggested_by_account_id is not null then
    insert into public.user_stats (account_id) values (v_suggestion.suggested_by_account_id)
      on conflict (account_id) do nothing;

    select approved_suggestions into v_count
      from public.user_stats where account_id = v_suggestion.suggested_by_account_id;

    if coalesce(v_count, 0) = 0 then
      v_xp_amount := 50; v_xp_reason := 'first_approved_suggestion';
    else
      v_xp_amount := 15; v_xp_reason := 'approved_suggestion';
    end if;

    update public.user_stats
       set approved_suggestions = coalesce(approved_suggestions, 0) + 1,
           updated_at = now()
     where account_id = v_suggestion.suggested_by_account_id;

    perform public.internal_award_xp(
      v_suggestion.suggested_by_account_id,
      v_xp_amount, v_xp_reason,
      jsonb_build_object('suggestion_id', p_suggestion_id, 'animal_name', v_suggestion.name),
      null, false
    );
  end if;

  return jsonb_build_object('ok', true, 'animal', to_jsonb(v_animal));
end;
$$;
grant execute on function public.approve_animal_suggestion(uuid, uuid) to anon, authenticated;

-- ============================================================
--  13) RPC: reject_animal_suggestion
-- ============================================================
drop function if exists public.reject_animal_suggestion(uuid, uuid, text);
create or replace function public.reject_animal_suggestion(
  p_session_token uuid,
  p_suggestion_id uuid,
  p_reason text
)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_session public.account_sessions;
  v_account public.accounts;
  v_suggestion public.animal_suggestions;
begin
  select * into v_session from public.account_sessions
    where token = p_session_token and expires_at > now();
  if not found then raise exception 'Bitte anmelden.'; end if;
  select * into v_account from public.accounts where id = v_session.account_id;
  if not coalesce(v_account.is_admin, false) then raise exception 'Nur Admins dürfen ablehnen.'; end if;
  if length(coalesce(trim(p_reason), '')) < 3 then
    raise exception 'Bitte einen Grund (mind. 3 Zeichen) angeben.';
  end if;

  select * into v_suggestion from public.animal_suggestions where id = p_suggestion_id;
  if not found then raise exception 'Vorschlag nicht gefunden.'; end if;
  if v_suggestion.status <> 'pending' then
    raise exception 'Vorschlag wurde bereits bearbeitet.';
  end if;

  update public.animal_suggestions
     set status = 'rejected', review_reason = trim(p_reason),
         reviewed_by_account_id = v_account.id, reviewed_at = now()
   where id = p_suggestion_id;

  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.reject_animal_suggestion(uuid, uuid, text) to anon, authenticated;

-- ============================================================
--  14) RPC: record_game_finish (XP nach Spielende)
-- ============================================================
drop function if exists public.record_game_finish(uuid, uuid);
create or replace function public.record_game_finish(
  p_session_token uuid,
  p_game_id uuid
)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_session public.account_sessions;
  v_account public.accounts;
  v_game public.games;
  v_player public.game_players;
  v_chain_length int;
  v_own_moves int;
  v_active_count int;
  v_player_count int;
  v_is_winner boolean;
  v_base int := 0;
  v_chain_bonus int := 0;
  v_streak_mult numeric := 1.0;
  v_win_xp int := 0;
  v_record_bonus int := 0;
  v_total int;
  v_credited int;
  v_already int;
  v_milestone int;
  v_old_record int;
  v_last_elim timestamptz;
  v_stats public.user_stats;
begin
  select * into v_session from public.account_sessions
    where token = p_session_token and expires_at > now();
  if not found then raise exception 'Bitte anmelden.'; end if;
  select * into v_account from public.accounts where id = v_session.account_id;

  select * into v_game from public.games where id = p_game_id;
  if not found then raise exception 'Spiel nicht gefunden.'; end if;

  select * into v_player from public.game_players
    where game_id = p_game_id and account_id = v_account.id;
  if not found then raise exception 'Du warst in diesem Spiel nicht angemeldet.'; end if;

  -- Idempotenz
  select count(*) into v_already from public.xp_log
    where game_id = p_game_id and account_id = v_account.id and reason = 'game_finish';
  if v_already > 0 then
    select * into v_stats from public.user_stats where account_id = v_account.id;
    return jsonb_build_object(
      'ok', true, 'already_credited', true,
      'total_xp', v_stats.total_xp, 'level', v_stats.level
    );
  end if;

  if v_game.status <> 'finished' then raise exception 'Spiel läuft noch.'; end if;

  insert into public.user_stats (account_id) values (v_account.id) on conflict do nothing;

  select count(*) into v_chain_length from public.moves where game_id = p_game_id;
  select count(*) into v_own_moves   from public.moves where game_id = p_game_id and game_player_id = v_player.id;
  select count(*) into v_player_count from public.game_players where game_id = p_game_id;
  select count(*) into v_active_count from public.game_players
    where game_id = p_game_id and is_eliminated = false;

  -- Spiel zu kurz → 0 XP, aber Log-Eintrag fürs Idempotenz-Tracking
  if v_chain_length < 5 then
    insert into public.xp_log (account_id, amount, reason, game_id, metadata)
      values (v_account.id, 0, 'game_finish', p_game_id,
              jsonb_build_object('skipped', 'short_game',
                                 'chain_length', v_chain_length,
                                 'own_moves', v_own_moves,
                                 'is_winner', false));
    return jsonb_build_object('ok', true, 'awarded', 0,
      'reason', 'Spiel zu kurz (< 5 Züge)');
  end if;

  v_is_winner := (not v_player.is_eliminated) and v_active_count = 1;

  -- Basis-XP
  v_base := 5 + v_own_moves;
  if v_player.turn_order = 1 then v_base := v_base + 2; end if;

  -- Sieg / Streak / 2. Platz
  if v_is_winner then
    update public.user_stats
       set current_streak = current_streak + 1,
           best_streak = greatest(best_streak, current_streak + 1),
           games_won = games_won + 1
     where account_id = v_account.id;
    select * into v_stats from public.user_stats where account_id = v_account.id;

    if v_stats.current_streak >= 10 then v_streak_mult := 2.0;
    elsif v_stats.current_streak >= 5 then v_streak_mult := 1.75;
    elsif v_stats.current_streak >= 3 then v_streak_mult := 1.5;
    elsif v_stats.current_streak >= 2 then v_streak_mult := 1.25;
    end if;
    v_win_xp := floor(20 * v_streak_mult)::int;
  else
    update public.user_stats set current_streak = 0 where account_id = v_account.id;
    if v_player_count >= 3 and v_player.eliminated_at is not null then
      select max(eliminated_at) into v_last_elim from public.game_players
        where game_id = p_game_id and is_eliminated = true;
      if v_player.eliminated_at = v_last_elim then
        v_win_xp := 8;
      end if;
    end if;
  end if;

  -- Kettenbonus
  if v_chain_length >= 60 then v_chain_bonus := 20;
  elsif v_chain_length >= 40 then v_chain_bonus := 10;
  elsif v_chain_length >= 20 then v_chain_bonus := 5;
  end if;

  -- Persönlicher Rekord
  select longest_chain into v_old_record from public.user_stats where account_id = v_account.id;
  if v_chain_length > coalesce(v_old_record, 0) then
    v_record_bonus := 25;
    update public.user_stats set longest_chain = v_chain_length where account_id = v_account.id;
  end if;

  update public.user_stats set games_played = games_played + 1 where account_id = v_account.id;

  -- Meilenstein-Boni (außerhalb Daily-Cap)
  select games_played into v_milestone from public.user_stats where account_id = v_account.id;
  if v_milestone = 1 then
    perform public.internal_award_xp(v_account.id, 20, 'milestone_first_game', null, null, false);
  elsif v_milestone = 10 then
    perform public.internal_award_xp(v_account.id, 25, 'milestone_10_games', null, null, false);
  elsif v_milestone = 50 then
    perform public.internal_award_xp(v_account.id, 75, 'milestone_50_games', null, null, false);
  elsif v_milestone = 100 then
    perform public.internal_award_xp(v_account.id, 200, 'milestone_100_games', null, null, false);
  elsif v_milestone = 500 then
    perform public.internal_award_xp(v_account.id, 1000, 'milestone_500_games', null, null, false);
  end if;

  v_total := v_base + v_win_xp + v_chain_bonus + v_record_bonus;
  v_credited := public.internal_award_xp(
    v_account.id, v_total, 'game_finish',
    jsonb_build_object(
      'base', v_base, 'win_xp', v_win_xp, 'chain_bonus', v_chain_bonus,
      'record_bonus', v_record_bonus, 'streak_mult', v_streak_mult,
      'chain_length', v_chain_length, 'own_moves', v_own_moves,
      'is_winner', v_is_winner, 'player_count', v_player_count
    ),
    p_game_id, true
  );

  select * into v_stats from public.user_stats where account_id = v_account.id;

  return jsonb_build_object(
    'ok', true,
    'awarded', v_credited,
    'requested', v_total,
    'is_winner', v_is_winner,
    'chain_length', v_chain_length,
    'own_moves', v_own_moves,
    'streak', v_stats.current_streak,
    'total_xp', v_stats.total_xp,
    'level', v_stats.level
  );
end;
$$;
grant execute on function public.record_game_finish(uuid, uuid) to anon, authenticated;

-- ============================================================
--  15) validate_session / login_account / register_account — is_admin mit ausliefern
-- ============================================================
drop function if exists public.validate_session(uuid);
create or replace function public.validate_session(p_token uuid)
returns jsonb language plpgsql security definer set search_path = public
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
      'created_at', v_account.created_at,
      'is_admin', coalesce(v_account.is_admin, false)
    ),
    'expires_at', v_session.expires_at
  );
end;
$$;
grant execute on function public.validate_session(uuid) to anon, authenticated;

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
  if not found then raise exception 'Falscher Benutzername oder PIN.'; end if;
  if not public.account_verify_pin(p_pin, v_account.pin_hash) then
    raise exception 'Falscher Benutzername oder PIN.';
  end if;

  update public.accounts set last_login_at = now() where id = v_account.id;
  delete from public.account_sessions
    where account_id = v_account.id and expires_at < now();

  insert into public.account_sessions (account_id)
    values (v_account.id) returning * into v_session;

  -- user_stats sicherstellen
  insert into public.user_stats (account_id) values (v_account.id) on conflict do nothing;

  return jsonb_build_object(
    'account', jsonb_build_object(
      'id', v_account.id, 'username', v_account.username,
      'avatar_emoji', v_account.avatar_emoji,
      'created_at', v_account.created_at,
      'is_admin', coalesce(v_account.is_admin, false)
    ),
    'session_token', v_session.token,
    'expires_at', v_session.expires_at
  );
end;
$$;
grant execute on function public.login_account(text, text) to anon, authenticated;

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
  if exists (select 1 from public.accounts where username = v_user) then
    raise exception 'Benutzername "%" ist bereits vergeben.', v_user;
  end if;

  v_avatar := coalesce(nullif(trim(p_avatar_emoji), ''), '🦊');
  if char_length(v_avatar) > 8 then v_avatar := '🦊'; end if;

  insert into public.accounts (username, pin_hash, avatar_emoji)
    values (v_user, public.account_hash_pin(p_pin), v_avatar)
    returning * into v_account;

  insert into public.account_sessions (account_id) values (v_account.id) returning * into v_session;
  insert into public.user_stats (account_id) values (v_account.id) on conflict do nothing;

  return jsonb_build_object(
    'account', jsonb_build_object(
      'id', v_account.id, 'username', v_account.username,
      'avatar_emoji', v_account.avatar_emoji,
      'created_at', v_account.created_at,
      'is_admin', coalesce(v_account.is_admin, false)
    ),
    'session_token', v_session.token,
    'expires_at', v_session.expires_at
  );
end;
$$;
grant execute on function public.register_account(text, text, text) to anon, authenticated;

-- ============================================================
--  16) ADMIN-ACCOUNT SEEDEN: UgaaaBugga / 6767
--  Username wird in lowercase normalisiert ("ugaaabugga"),
--  PIN wird gehasht. Bei jedem Migrationsdurchlauf zurückgesetzt
--  (PIN und Admin-Flag), damit du den Zugang sicher wieder erlangst.
-- ============================================================
do $$
declare
  v_id uuid;
begin
  if exists (select 1 from public.accounts where username = 'ugaaabugga') then
    update public.accounts
       set is_admin = true,
           pin_hash = public.account_hash_pin('6767'),
           avatar_emoji = coalesce(nullif(avatar_emoji, ''), '👑')
     where username = 'ugaaabugga';
  else
    insert into public.accounts (username, pin_hash, avatar_emoji, is_admin)
    values ('ugaaabugga', public.account_hash_pin('6767'), '👑', true)
    returning id into v_id;
  end if;

  insert into public.user_stats (account_id)
    select id from public.accounts where username = 'ugaaabugga'
    on conflict do nothing;
end $$;
