-- Elite FF Tournaments: allow a player to add/replace the screenshot on their own pending deposit.
-- This function does not change the deposit amount, UTR, or status.
-- Safe to re-run.

BEGIN;

CREATE OR REPLACE FUNCTION public.update_pending_deposit_proof(
    p_deposit_id uuid,
    p_payment_proof_path text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Login required';
    END IF;

    IF p_payment_proof_path IS NULL
       OR left(p_payment_proof_path, length(auth.uid()::text) + 1)
          <> auth.uid()::text || '/' THEN
        RAISE EXCEPTION 'Invalid screenshot path';
    END IF;

    UPDATE public.deposits
    SET payment_proof_path = p_payment_proof_path
    WHERE id = p_deposit_id
      AND user_id = auth.uid()
      AND status = 'pending';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Pending deposit not found';
    END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.update_pending_deposit_proof(uuid, text)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.update_pending_deposit_proof(uuid, text)
TO authenticated;

COMMIT;
