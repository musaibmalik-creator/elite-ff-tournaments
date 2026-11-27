-- ELITE FF: AUTOMATIC, IDEMPOTENT PRIZE WALLET CREDIT
-- Run once in Supabase SQL Editor after player_match_results.sql and leaderboard_winnings.sql.
-- Credits each submitted prize exactly once. If an admin corrects a result,
-- only the difference is applied. A reduction that would make wallet negative
-- is rejected so an already-spent prize is never silently clawed back.

BEGIN;

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

    INSERT INTO public.wallet_transactions(user_id,amount,type,status,reference_id)
    VALUES(
      NEW.user_id,
      delta,
      CASE WHEN delta > 0 THEN 'tournament_prize' ELSE 'tournament_prize_adjustment' END,
      'completed',
      NEW.id
    );

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

COMMIT;
