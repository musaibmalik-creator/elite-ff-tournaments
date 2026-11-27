-- MANUAL SLOT SELECTION + INDIVIDUAL WALLET PAYMENT
-- Run this complete file in Supabase SQL Editor.
-- Existing registrations and wallet balances are preserved.

BEGIN;

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
  IF lower(coalesce(tour.status,'')) IN ('closed','completed','cancelled','full') THEN
    RAISE EXCEPTION 'Tournament is not accepting players.';
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

  IF team_players >= capacity THEN
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
    'team_players',team_players,
    'team_capacity',capacity,
    'team_status',CASE WHEN team_players>=capacity THEN 'confirmed' ELSE 'pending' END,
    'charged',coalesce(tour.entry_fee,0)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.join_tournament_with_wallet(uuid,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.join_tournament_with_wallet(uuid,integer) TO authenticated;

COMMIT;
