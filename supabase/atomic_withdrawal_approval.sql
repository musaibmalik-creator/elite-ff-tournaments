-- Atomic withdrawal approval/rejection.
-- Run this migration in Supabase SQL Editor before using the updated admin app.
DROP FUNCTION IF EXISTS public.approve_withdrawal_and_debit_wallet(uuid);

CREATE OR REPLACE FUNCTION public.approve_withdrawal_and_debit_wallet(
  p_withdrawal_id uuid,
  p_payment_details text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_withdrawal public.withdrawals%ROWTYPE;
  v_wallet public.wallets%ROWTYPE;
  v_new_balance numeric;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Login required'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RAISE EXCEPTION 'Admin access required';
  END IF;
  IF p_payment_details IS NULL OR btrim(p_payment_details) = '' THEN
    RAISE EXCEPTION 'UTR/payment reference is required';
  END IF;

  SELECT * INTO v_withdrawal FROM public.withdrawals
  WHERE id = p_withdrawal_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Withdrawal not found'; END IF;
  IF v_withdrawal.status <> 'pending' THEN RAISE EXCEPTION 'Withdrawal is not pending'; END IF;
  -- User proof is not required before admin approval.\n  -- Bank-statement screenshot is requested only if the user reports non-receipt.\n
  SELECT * INTO v_wallet FROM public.wallets
  WHERE user_id = v_withdrawal.user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Wallet not found'; END IF;
  IF COALESCE(v_wallet.balance, 0) < v_withdrawal.amount THEN
    RAISE EXCEPTION 'Insufficient wallet balance';
  END IF;

  v_new_balance := COALESCE(v_wallet.balance, 0) - v_withdrawal.amount;
  UPDATE public.wallets SET balance = v_new_balance WHERE user_id = v_withdrawal.user_id;
  UPDATE public.withdrawals
  SET status = 'approved',
      payment_details = btrim(p_payment_details),
      paid_at = now(),
      rejection_reason = NULL
  WHERE id = p_withdrawal_id;

  RETURN json_build_object('success', true, 'amount', v_withdrawal.amount,
    'payout_amount', v_withdrawal.payout_amount, 'new_balance', v_new_balance);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_reject_withdrawal(
  p_withdrawal_id uuid,
  p_rejection_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_withdrawal public.withdrawals%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Login required'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RAISE EXCEPTION 'Admin access required';
  END IF;
  IF p_rejection_reason IS NULL OR btrim(p_rejection_reason) = '' THEN
    RAISE EXCEPTION 'Rejection reason is required';
  END IF;

  SELECT * INTO v_withdrawal FROM public.withdrawals
  WHERE id = p_withdrawal_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Withdrawal not found'; END IF;
  IF v_withdrawal.status <> 'pending' THEN RAISE EXCEPTION 'Withdrawal is not pending'; END IF;

  UPDATE public.withdrawals
  SET status = 'rejected', rejection_reason = btrim(p_rejection_reason)
  WHERE id = p_withdrawal_id;

  RETURN jsonb_build_object('success', true, 'status', 'rejected');
END;
$function$;

REVOKE ALL ON FUNCTION public.approve_withdrawal_and_debit_wallet(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_reject_withdrawal(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.approve_withdrawal_and_debit_wallet(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_reject_withdrawal(uuid, text) TO authenticated;
