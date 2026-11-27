-- Elite FF Tournaments: allow each signed-in player to read their own wallet history.
-- Safe to re-run. Existing policies are preserved; policies combine with OR.

DROP POLICY IF EXISTS "Players read own deposit history" ON public.deposits;
CREATE POLICY "Players read own deposit history"
ON public.deposits
FOR SELECT
TO authenticated
USING (user_id = auth.uid());

DROP POLICY IF EXISTS "Players read own withdrawal history" ON public.withdrawals;
CREATE POLICY "Players read own withdrawal history"
ON public.withdrawals
FOR SELECT
TO authenticated
USING (user_id = auth.uid());

DROP POLICY IF EXISTS "Admins read all deposit history" ON public.deposits;
CREATE POLICY "Admins read all deposit history"
ON public.deposits
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = auth.uid() AND p.role = 'admin'
  )
);

DROP POLICY IF EXISTS "Admins read all withdrawal history" ON public.withdrawals;
CREATE POLICY "Admins read all withdrawal history"
ON public.withdrawals
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = auth.uid() AND p.role = 'admin'
  )
);
