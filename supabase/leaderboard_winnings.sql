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
