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
  ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();

CREATE UNIQUE INDEX IF NOT EXISTS player_match_results_tournament_user_uidx
  ON public.player_match_results(tournament_id,user_id);

ALTER TABLE public.player_match_results ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Players view own match results or admins view all" ON public.player_match_results;
CREATE POLICY "Players view own match results or admins view all"
ON public.player_match_results FOR SELECT TO authenticated
USING (
  user_id = auth.uid()
  OR EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid() AND profiles.role = 'admin'
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

COMMIT;
