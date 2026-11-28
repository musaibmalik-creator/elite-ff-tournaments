-- ELITE FF TOURNAMENTS — CORE DATABASE SETUP
-- Run this complete file once in Supabase SQL Editor.
-- Safe to re-run for these project migrations.
-- Deposit and withdrawal migrations are intentionally excluded.
-- Existing wallet balances and player registrations are preserved.

BEGIN;

-- =====================================================
-- 1. LEADERBOARD
-- Source: supabase/leaderboard_winnings.sql
-- =====================================================
-- Elite FF Tournaments: winning-only leaderboard
CREATE TABLE IF NOT EXISTS public.leaderboard_winnings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  player_name text NOT NULL,
  player_uid text NOT NULL,
  tournament_id uuid NOT NULL REFERENCES public.tournaments(id) ON DELETE CASCADE,
  amount numeric(12,2) NOT NULL CHECK (amount > 0),
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.leaderboard_winnings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Authenticated users can view leaderboard winnings" ON public.leaderboard_winnings;
CREATE POLICY "Authenticated users can view leaderboard winnings"
ON public.leaderboard_winnings
FOR SELECT
TO authenticated
USING (true);

DROP POLICY IF EXISTS "Admins can add leaderboard winnings" ON public.leaderboard_winnings;
CREATE POLICY "Admins can add leaderboard winnings"
ON public.leaderboard_winnings
FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM public.profiles
    WHERE profiles.id = auth.uid()
      AND profiles.role = 'admin'
  )
);

DROP POLICY IF EXISTS "Admins can update leaderboard winnings" ON public.leaderboard_winnings;
CREATE POLICY "Admins can update leaderboard winnings"
ON public.leaderboard_winnings
FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid() AND profiles.role = 'admin'
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid() AND profiles.role = 'admin'
  )
);

DROP POLICY IF EXISTS "Admins can delete leaderboard winnings" ON public.leaderboard_winnings;
CREATE POLICY "Admins can delete leaderboard winnings"
ON public.leaderboard_winnings
FOR DELETE
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid() AND profiles.role = 'admin'
  )
);

GRANT SELECT ON public.leaderboard_winnings TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.leaderboard_winnings TO authenticated;

-- =====================================================
-- 2. MATCH RESULTS
-- Source: supabase/player_match_results.sql
-- =====================================================
-- PLAYER MATCH RESULTS + AUTOMATIC MATCHES PLAYED
-- Run this complete file in Supabase SQL Editor.
-- Existing completed tournaments are backfilled, so earlier completed matches count too.

CREATE TABLE IF NOT EXISTS public.player_match_results (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tournament_id uuid NOT NULL REFERENCES public.tournaments(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  player_name text NOT NULL DEFAULT 'Player',
  player_uid text NOT NULL DEFAULT '',
  kills integer NOT NULL DEFAULT 0 CHECK (kills >= 0),
  is_winner boolean NOT NULL DEFAULT false,
  prize_amount numeric(12,2) NOT NULL DEFAULT 0 CHECK (prize_amount >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT player_match_results_tournament_user_unique UNIQUE (tournament_id,user_id)
);

ALTER TABLE public.player_match_results
  ADD COLUMN IF NOT EXISTS player_name text NOT NULL DEFAULT 'Player',
  ADD COLUMN IF NOT EXISTS player_uid text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS kills integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS is_winner boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS prize_amount numeric(12,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS results_submitted boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();

CREATE UNIQUE INDEX IF NOT EXISTS player_match_results_tournament_user_uidx
  ON public.player_match_results(tournament_id,user_id);

ALTER TABLE public.player_match_results ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Players view own match results or admins view all" ON public.player_match_results;
DROP POLICY IF EXISTS "Authenticated users view results of completed tournaments" ON public.player_match_results;

-- Before completion, players can only see their own result.
-- Once admin marks the tournament complete, all signed-in players can see
-- every participant's kills, winner status and winning amount.
CREATE POLICY "Players view own match results or admins view all"
ON public.player_match_results FOR SELECT TO authenticated
USING (
  user_id = auth.uid()
  OR EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid() AND profiles.role = 'admin'
  )
  OR EXISTS (
    SELECT 1 FROM public.tournaments t
    WHERE t.id = player_match_results.tournament_id
      AND lower(coalesce(t.status,'')) IN ('complete','completed')
  )
);

DROP POLICY IF EXISTS "Admins manage player match results" ON public.player_match_results;
CREATE POLICY "Admins manage player match results"
ON public.player_match_results FOR ALL TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid() AND profiles.role = 'admin'
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid() AND profiles.role = 'admin'
  )
);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.player_match_results TO authenticated;

CREATE OR REPLACE FUNCTION public.record_completed_tournament_players()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF lower(coalesce(NEW.status,'')) IN ('complete','completed')
     AND lower(coalesce(OLD.status,'')) NOT IN ('complete','completed') THEN

    INSERT INTO public.player_match_results
      (tournament_id,user_id,player_name,player_uid)
    SELECT DISTINCT
      NEW.id,
      p.user_id,
      coalesce(nullif(p.name,''),'Player'),
      coalesce(p.uid,'')
    FROM public.players p
    WHERE p.tournament_id = NEW.id
      AND p.status = 'confirmed'
      AND p.user_id IS NOT NULL
    ON CONFLICT (tournament_id,user_id) DO NOTHING;

  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_record_completed_tournament_players ON public.tournaments;
CREATE TRIGGER trg_record_completed_tournament_players
AFTER UPDATE OF status ON public.tournaments
FOR EACH ROW
EXECUTE FUNCTION public.record_completed_tournament_players();

-- Backfill: include confirmed players from tournaments already marked Complete.
INSERT INTO public.player_match_results
  (tournament_id,user_id,player_name,player_uid)
SELECT DISTINCT
  t.id,
  p.user_id,
  coalesce(nullif(p.name,''),'Player'),
  coalesce(p.uid,'')
FROM public.tournaments t
JOIN public.players p ON p.tournament_id = t.id
WHERE lower(coalesce(t.status,'')) IN ('complete','completed')
  AND p.status = 'confirmed'
  AND p.user_id IS NOT NULL
ON CONFLICT (tournament_id,user_id) DO NOTHING;


-- Keep one leaderboard row per player per tournament so resubmitting
-- corrected results updates the amount instead of double-counting it.
DO $$
DECLARE
  item record;
BEGIN
  FOR item IN
    SELECT tournament_id,user_id,sum(amount) AS total_amount,
           (array_agg(id ORDER BY created_at DESC,id DESC))[1] AS keep_id
    FROM public.leaderboard_winnings
    WHERE user_id IS NOT NULL
    GROUP BY tournament_id,user_id
    HAVING count(*) > 1
  LOOP
    UPDATE public.leaderboard_winnings
    SET amount=item.total_amount
    WHERE id=item.keep_id;

    DELETE FROM public.leaderboard_winnings
    WHERE tournament_id=item.tournament_id
      AND user_id=item.user_id
      AND id<>item.keep_id;
  END LOOP;
END;
$$;

CREATE UNIQUE INDEX IF NOT EXISTS leaderboard_winnings_tournament_user_uidx
  ON public.leaderboard_winnings(tournament_id,user_id);

-- One secure database transaction saves every player's stats and winnings.
CREATE OR REPLACE FUNCTION public.admin_save_tournament_results(
  p_tournament_id uuid,
  p_results jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  result_count integer;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id=auth.uid() AND role='admin'
  ) THEN
    RAISE EXCEPTION 'Only admins can submit match results';
  END IF;

  IF p_results IS NULL OR jsonb_typeof(p_results)<>'array' THEN
    RAISE EXCEPTION 'Invalid results data';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.tournaments WHERE id=p_tournament_id) THEN
    RAISE EXCEPTION 'Tournament not found';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(p_results) AS x(
      user_id uuid,
      kills integer,
      prize_amount numeric
    )
    WHERE x.user_id IS NULL
       OR coalesce(x.kills,-1)<0
       OR coalesce(x.prize_amount,-1)<0
  ) THEN
    RAISE EXCEPTION 'Invalid player result values';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(p_results) AS x(user_id uuid)
    WHERE NOT EXISTS (
      SELECT 1 FROM public.players p
      WHERE p.tournament_id=p_tournament_id
        AND p.user_id=x.user_id
        AND p.status='confirmed'
    )
  ) THEN
    RAISE EXCEPTION 'A player is not confirmed in this tournament';
  END IF;

  INSERT INTO public.player_match_results
    (tournament_id,user_id,player_name,player_uid,kills,is_winner,prize_amount,results_submitted)
  SELECT
    p_tournament_id,
    x.user_id,
    coalesce(nullif(x.player_name,''),'Player'),
    coalesce(x.player_uid,''),
    x.kills,
    coalesce(x.is_winner,false),
    x.prize_amount,
    true
  FROM jsonb_to_recordset(p_results) AS x(
    user_id uuid,
    player_name text,
    player_uid text,
    kills integer,
    is_winner boolean,
    prize_amount numeric
  )
  ON CONFLICT (tournament_id,user_id) DO UPDATE SET
    player_name=EXCLUDED.player_name,
    player_uid=EXCLUDED.player_uid,
    kills=EXCLUDED.kills,
    is_winner=EXCLUDED.is_winner,
    prize_amount=EXCLUDED.prize_amount,
    results_submitted=true;

  INSERT INTO public.leaderboard_winnings
    (user_id,player_name,player_uid,tournament_id,amount)
  SELECT
    x.user_id,
    coalesce(nullif(x.player_name,''),'Player'),
    coalesce(x.player_uid,''),
    p_tournament_id,
    x.prize_amount
  FROM jsonb_to_recordset(p_results) AS x(
    user_id uuid,
    player_name text,
    player_uid text,
    prize_amount numeric
  )
  WHERE x.prize_amount>0
  ON CONFLICT (tournament_id,user_id) DO UPDATE SET
    player_name=EXCLUDED.player_name,
    player_uid=EXCLUDED.player_uid,
    amount=EXCLUDED.amount,
    created_at=now();

  DELETE FROM public.leaderboard_winnings lw
  USING jsonb_to_recordset(p_results) AS x(user_id uuid,prize_amount numeric)
  WHERE lw.tournament_id=p_tournament_id
    AND lw.user_id=x.user_id
    AND coalesce(x.prize_amount,0)=0;

  SELECT count(*) INTO result_count
  FROM jsonb_to_recordset(p_results) AS x(user_id uuid);

  RETURN jsonb_build_object('saved',true,'players',result_count);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_save_tournament_results(uuid,jsonb)
  TO authenticated;

-- =====================================================
-- 3. AUTOMATIC PRIZE WALLET CREDIT
-- Source: supabase/prize_wallet_payout.sql
-- =====================================================
-- ELITE FF: AUTOMATIC, IDEMPOTENT PRIZE WALLET CREDIT
-- Run once in Supabase SQL Editor after player_match_results.sql and leaderboard_winnings.sql.
-- Credits each submitted prize exactly once. If an admin corrects a result,
-- only the difference is applied. A reduction that would make wallet negative
-- is rejected so an already-spent prize is never silently clawed back.

CREATE TABLE IF NOT EXISTS public.player_prize_payouts (
  result_id uuid PRIMARY KEY REFERENCES public.player_match_results(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  tournament_id uuid NOT NULL REFERENCES public.tournaments(id) ON DELETE CASCADE,
  paid_amount numeric(12,2) NOT NULL DEFAULT 0 CHECK (paid_amount >= 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.player_prize_payouts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.player_prize_payouts FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.apply_player_prize_wallet_credit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  previous_paid numeric(12,2) := 0;
  desired_paid numeric(12,2) := 0;
  delta numeric(12,2) := 0;
  current_balance numeric(12,2);
BEGIN
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;

  IF NOT coalesce(NEW.results_submitted,false) THEN
    RETURN NEW;
  END IF;

  desired_paid := round(greatest(coalesce(NEW.prize_amount,0),0),2);

  INSERT INTO public.player_prize_payouts(result_id,user_id,tournament_id,paid_amount)
  VALUES(NEW.id,NEW.user_id,NEW.tournament_id,0)
  ON CONFLICT (result_id) DO NOTHING;

  SELECT paid_amount INTO previous_paid
  FROM public.player_prize_payouts
  WHERE result_id=NEW.id
  FOR UPDATE;

  delta := desired_paid - coalesce(previous_paid,0);

  IF delta <> 0 THEN
    SELECT balance INTO current_balance
    FROM public.wallets
    WHERE user_id=NEW.user_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Wallet not found for prize winner %', NEW.user_id;
    END IF;

    IF current_balance + delta < 0 THEN
      RAISE EXCEPTION 'Prize correction cannot be applied: player has already used part of the credited prize';
    END IF;

    UPDATE public.wallets
    SET balance=balance+delta, updated_at=now()
    WHERE user_id=NEW.user_id;

    -- The wallet_transactions_type_check constraint allows the existing 'prize' type.
    INSERT INTO public.wallet_transactions(user_id,amount,type,status,reference_id)
    VALUES(NEW.user_id,delta,'prize','completed',NEW.id);

    UPDATE public.player_prize_payouts
    SET user_id=NEW.user_id,
        tournament_id=NEW.tournament_id,
        paid_amount=desired_paid,
        updated_at=now()
    WHERE result_id=NEW.id;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_apply_player_prize_wallet_credit
ON public.player_match_results;

CREATE TRIGGER trg_apply_player_prize_wallet_credit
AFTER INSERT OR UPDATE OF prize_amount, results_submitted, user_id
ON public.player_match_results
FOR EACH ROW
EXECUTE FUNCTION public.apply_player_prize_wallet_credit();

-- Backfill any results that were already submitted before this migration.
DO $$
DECLARE
  result_row record;
BEGIN
  FOR result_row IN
    SELECT id,user_id,tournament_id,prize_amount,results_submitted
    FROM public.player_match_results
    WHERE results_submitted=true AND prize_amount>0
    ORDER BY created_at,id
  LOOP
    UPDATE public.player_match_results
    SET prize_amount=result_row.prize_amount
    WHERE id=result_row.id;
  END LOOP;
END;
$$;

-- =====================================================
-- 4. ROOM DETAIL SECURITY
-- Source: supabase/secure_room_details_confirmed_players.sql
-- =====================================================
-- Room details must only be readable by fully confirmed players or admins.
-- This replaces existing SELECT policies for this table so an older
-- captain/any-player policy cannot continue granting room access.

ALTER TABLE public.tournament_room_details ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE
  existing_policy record;
BEGIN
  FOR existing_policy IN
    SELECT policyname
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'tournament_room_details'
      AND cmd = 'SELECT'
  LOOP
    EXECUTE format(
      'DROP POLICY IF EXISTS %I ON public.tournament_room_details',
      existing_policy.policyname
    );
  END LOOP;
END
$$;

CREATE POLICY "Admins and confirmed players can view room details"
ON public.tournament_room_details
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.profiles profile
    WHERE profile.id = auth.uid()
      AND profile.role = 'admin'
  )
  OR EXISTS (
    SELECT 1
    FROM public.players player
    WHERE player.tournament_id = tournament_room_details.tournament_id
      AND player.user_id = auth.uid()
      AND player.status = 'confirmed'
      AND EXISTS (
        SELECT 1
        FROM public.tournaments tournament
        WHERE tournament.id = player.tournament_id
          AND tournament.starts_at IS NOT NULL
          AND now() >= tournament.starts_at - interval '7 minutes'
      )
  )
);

-- Keep the existing admin-only ALL policy in place for room management.

-- =====================================================
-- 5. NOTIFICATIONS DATABASE
-- Source: supabase/notifications.sql
-- =====================================================
-- Elite FF Tournaments: push notifications
-- Run this file once in Supabase SQL Editor.

create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  fcm_token text not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.push_subscriptions enable row level security;

drop policy if exists "Users manage own push subscriptions" on public.push_subscriptions;
create policy "Users manage own push subscriptions"
on public.push_subscriptions
for all
to authenticated
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

create table if not exists public.user_notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  title text not null,
  body text not null,
  notification_type text not null default 'general'
    check (notification_type in ('general','room_released')),
  tournament_id uuid null references public.tournaments(id) on delete set null,
  created_at timestamptz not null default now(),
  read_at timestamptz null
);

create index if not exists user_notifications_user_created_idx
on public.user_notifications(user_id, created_at desc);

alter table public.user_notifications enable row level security;

drop policy if exists "Users read own notifications" on public.user_notifications;
create policy "Users read own notifications"
on public.user_notifications
for select
to authenticated
using (auth.uid() = user_id);

drop policy if exists "Users mark own notifications read" on public.user_notifications;
create policy "Users mark own notifications read"
on public.user_notifications
for update
to authenticated
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

-- Notification rows and FCM sends are created only by the Edge Function
-- using the Supabase service-role key. Never expose that key in HTML.

-- Explicit client grants; RLS still limits each user to their own rows.
grant select, insert, update, delete on public.push_subscriptions to authenticated;
grant select, update on public.user_notifications to authenticated;

-- =====================================================
-- 6. INDIVIDUAL SLOT JOIN + PAYMENT
-- Source: supabase/individual_tournament_join.sql
-- =====================================================
-- MANUAL SLOT SELECTION + INDIVIDUAL WALLET PAYMENT
-- Run this complete file in Supabase SQL Editor.
-- Existing registrations and wallet balances are preserved.

ALTER TABLE public.teams ALTER COLUMN captain_id DROP NOT NULL;

DROP FUNCTION IF EXISTS public.join_tournament_with_wallet(uuid);

CREATE OR REPLACE FUNCTION public.join_tournament_with_wallet(
  p_tournament_id uuid,
  p_slot_number integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
  u uuid := auth.uid();
  tour public.tournaments%ROWTYPE;
  prof public.profiles%ROWTYPE;
  wallet_balance numeric;
  mode text;
  capacity integer;
  total_slots integer;
  group_no integer;
  local_slot integer;
  group_name text;
  team_id_value uuid;
  player_id_value uuid;
  entry_id_value uuid;
  team_players integer;
  match_players integer;
  is_match_mode boolean;
BEGIN
  IF u IS NULL THEN RAISE EXCEPTION 'Please login first.'; END IF;
  IF p_slot_number IS NULL OR p_slot_number < 1 THEN
    RAISE EXCEPTION 'Please select a valid slot.';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('elite_ff_join'),hashtext(p_tournament_id::text));

  SELECT * INTO tour
  FROM public.tournaments
  WHERE id=p_tournament_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Tournament not found.'; END IF;
  IF lower(coalesce(tour.status,'')) NOT IN ('open','upcoming','registration_open') THEN
    RAISE EXCEPTION 'Tournament registration is closed.';
  END IF;
  IF tour.starts_at IS NOT NULL AND tour.starts_at <= now() THEN
    RAISE EXCEPTION 'Tournament registration has ended because the match has started.';
  END IF;
  IF coalesce(tour.entry_fee,0) < 0 THEN
    RAISE EXCEPTION 'Tournament entry fee cannot be negative.';
  END IF;

  IF EXISTS(
    SELECT 1 FROM public.players
    WHERE tournament_id=p_tournament_id AND user_id=u
  ) THEN
    RAISE EXCEPTION 'You have already joined this tournament.';
  END IF;

  SELECT * INTO prof FROM public.profiles WHERE id=u;
  IF NOT FOUND OR coalesce(trim(prof.ff_name),'')='' OR coalesce(trim(prof.ff_uid),'')='' THEN
    RAISE EXCEPTION 'Save your Free Fire Name and UID in Profile first.';
  END IF;

  mode := lower(coalesce(tour.sport,''));
  capacity := CASE mode
    WHEN 'cs_1v1' THEN 1 WHEN 'cs_2v2' THEN 2 WHEN 'cs_4v4' THEN 4
    WHEN 'br_solo' THEN 1 WHEN 'br_duo' THEN 2 WHEN 'br_squad' THEN 4
    WHEN 'lone_wolf' THEN 1 ELSE 0 END;

  IF capacity=0 THEN RAISE EXCEPTION 'Unsupported tournament mode.'; END IF;

  IF mode IN ('cs_1v1','cs_2v2','cs_4v4','lone_wolf') THEN
    total_slots := capacity * 2;
  ELSE
    total_slots := greatest(coalesce(tour.max_teams,0),0) * capacity;
  END IF;

  IF total_slots < 1 OR p_slot_number > total_slots THEN
    RAISE EXCEPTION 'Selected slot is outside the tournament capacity.';
  END IF;

  is_match_mode := mode IN ('cs_1v1','cs_2v2','cs_4v4','lone_wolf');

  IF mode IN ('cs_1v1','cs_2v2','cs_4v4') THEN
    group_no := ((p_slot_number-1) / capacity) + 1;
    local_slot := ((p_slot_number-1) % capacity) + 1;
    group_name := CASE WHEN group_no=1 THEN 'Team A' ELSE 'Team B' END;
  ELSIF mode='lone_wolf' THEN
    group_no := p_slot_number;
    local_slot := 1;
    group_name := CASE WHEN group_no=1 THEN 'Team A' ELSE 'Team B' END;
  ELSE
    group_no := ((p_slot_number-1) / capacity) + 1;
    local_slot := ((p_slot_number-1) % capacity) + 1;
    group_name := CASE mode
      WHEN 'br_solo' THEN 'Slot '||group_no
      WHEN 'br_duo' THEN 'Duo '||group_no
      ELSE 'Squad '||group_no END;
  END IF;

  IF EXISTS(
    SELECT 1
    FROM public.teams tm
    JOIN public.players pl ON pl.team_id=tm.id
    WHERE tm.tournament_id=p_tournament_id
      AND tm.name=group_name
      AND pl.slot_number=local_slot
      AND pl.user_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'This slot has already been taken. Please choose another slot.';
  END IF;

  SELECT balance INTO wallet_balance
  FROM public.wallets
  WHERE user_id=u
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Wallet not found. Please contact support.'; END IF;
  IF coalesce(wallet_balance,0) < coalesce(tour.entry_fee,0) THEN
    RAISE EXCEPTION 'Insufficient wallet balance. Deposit first.';
  END IF;

  SELECT id INTO team_id_value
  FROM public.teams
  WHERE tournament_id=p_tournament_id AND name=group_name
  ORDER BY created_at
  LIMIT 1
  FOR UPDATE;

  IF team_id_value IS NULL THEN
    INSERT INTO public.teams(tournament_id,captain_id,name)
    VALUES(p_tournament_id,NULL,group_name)
    RETURNING id INTO team_id_value;
  END IF;

  SELECT id INTO entry_id_value
  FROM public.tournament_entries
  WHERE tournament_id=p_tournament_id AND team_id=team_id_value
  ORDER BY created_at
  LIMIT 1;

  IF entry_id_value IS NULL THEN
    INSERT INTO public.tournament_entries(tournament_id,team_id,user_id,status)
    VALUES(p_tournament_id,team_id_value,u,'pending')
    RETURNING id INTO entry_id_value;
  END IF;

  UPDATE public.wallets
  SET balance=balance-coalesce(tour.entry_fee,0), updated_at=now()
  WHERE user_id=u;

  INSERT INTO public.players(
    team_id,name,team_name,tournament_id,uid,status,user_id,slot_number
  )
  VALUES(
    team_id_value,prof.ff_name,group_name,p_tournament_id,
    prof.ff_uid,'pending',u,local_slot
  )
  RETURNING id INTO player_id_value;

  INSERT INTO public.wallet_transactions(user_id,amount,type,status,reference_id)
  VALUES(u,-coalesce(tour.entry_fee,0),'tournament_entry','completed',player_id_value);

  SELECT count(*) INTO team_players
  FROM public.players
  WHERE team_id=team_id_value AND user_id IS NOT NULL;

  SELECT count(*) INTO match_players
  FROM public.players
  WHERE tournament_id=p_tournament_id AND user_id IS NOT NULL;

  IF is_match_mode THEN
    -- CS and Lone Wolf are one head-to-head match: both sides must fill
    -- before any player or team entry is marked confirmed.
    IF match_players >= total_slots THEN
      UPDATE public.tournament_entries
      SET status='confirmed'
      WHERE tournament_id=p_tournament_id;
      UPDATE public.players
      SET status='confirmed'
      WHERE tournament_id=p_tournament_id;
    END IF;
  ELSIF team_players >= capacity THEN
    -- BR Solo/Duo/Squad registrations confirm independently by squad.
    UPDATE public.tournament_entries SET status='confirmed' WHERE id=entry_id_value;
    UPDATE public.players SET status='confirmed' WHERE team_id=team_id_value;
  END IF;

  RETURN jsonb_build_object(
    'success',true,
    'team_id',team_id_value,
    'team_name',group_name,
    'player_id',player_id_value,
    'slot_number',p_slot_number,
    'team_slot_number',local_slot,
    'team_players',CASE WHEN is_match_mode THEN match_players ELSE team_players END,
    'team_capacity',CASE WHEN is_match_mode THEN total_slots ELSE capacity END,
    'match_players',match_players,
    'match_capacity',total_slots,
    'team_status',CASE
      WHEN is_match_mode AND match_players>=total_slots THEN 'confirmed'
      WHEN NOT is_match_mode AND team_players>=capacity THEN 'confirmed'
      ELSE 'pending'
    END,
    'charged',coalesce(tour.entry_fee,0)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.join_tournament_with_wallet(uuid,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.join_tournament_with_wallet(uuid,integer) TO authenticated;

-- =====================================================
-- 7. ADMIN ENTRY-FEE LEDGER READ ACCESS
-- Source: supabase/admin_entry_fee_ledger.sql
-- =====================================================
-- Allow each player to read their own wallet transaction history
-- and admins to read the full ledger for the admin entry-fee report.
-- This does not allow clients to insert, update, or delete wallet transactions.

ALTER TABLE public.wallet_transactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can read own wallet transactions" ON public.wallet_transactions;
CREATE POLICY "Users can read own wallet transactions"
ON public.wallet_transactions
FOR SELECT
TO authenticated
USING (user_id = auth.uid());

DROP POLICY IF EXISTS "Admins can read all wallet transactions" ON public.wallet_transactions;
CREATE POLICY "Admins can read all wallet transactions"
ON public.wallet_transactions
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.profiles
    WHERE profiles.id = auth.uid()
      AND profiles.role = 'admin'
  )
);

GRANT SELECT ON public.wallet_transactions TO authenticated;

COMMIT;
