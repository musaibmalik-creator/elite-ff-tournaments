-- Allow each player to read their own wallet transaction history
-- and admins to read the full ledger for the admin entry-fee report.
-- This does not allow clients to insert, update, or delete wallet transactions.

BEGIN;

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
