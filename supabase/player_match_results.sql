-- PLAYER MATCH RESULTS + AUTOMATIC MATCHES PLAYED
-- Run this complete file in Supabase SQL Editor.
-- Existing completed tournaments are backfilled, so earlier completed matches count too.

BEGIN;

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
DO $
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
$;

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
AS $
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
$;

GRANT EXECUTE ON FUNCTION public.admin_save_tournament_results(uuid,jsonb)
  TO authenticated;

COMMIT;
