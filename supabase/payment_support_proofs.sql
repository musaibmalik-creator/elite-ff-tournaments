-- Elite FF Tournaments: player deposit screenshots + withdrawal bank statement PDFs
-- Run this complete file in Supabase SQL Editor. Safe to re-run.

ALTER TABLE public.deposits ADD COLUMN IF NOT EXISTS payment_proof_path text;
ALTER TABLE public.withdrawals ADD COLUMN IF NOT EXISTS user_bank_statement_path text;

INSERT INTO storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
VALUES ('deposit-proofs','deposit-proofs',false,5242880,ARRAY['image/jpeg','image/png','image/webp'])
ON CONFLICT (id) DO UPDATE SET public=false,file_size_limit=5242880,allowed_mime_types=ARRAY['image/jpeg','image/png','image/webp'];

INSERT INTO storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
VALUES ('withdrawal-bank-statements','withdrawal-bank-statements',false,5242880,ARRAY['application/pdf'])
ON CONFLICT (id) DO UPDATE SET public=false,file_size_limit=5242880,allowed_mime_types=ARRAY['application/pdf'];

DROP POLICY IF EXISTS "Players upload own deposit screenshots" ON storage.objects;
CREATE POLICY "Players upload own deposit screenshots" ON storage.objects FOR INSERT TO authenticated
WITH CHECK (bucket_id='deposit-proofs' AND (storage.foldername(name))[1]=auth.uid()::text);
DROP POLICY IF EXISTS "Players read own deposit screenshots" ON storage.objects;
CREATE POLICY "Players read own deposit screenshots" ON storage.objects FOR SELECT TO authenticated
USING (bucket_id='deposit-proofs' AND (storage.foldername(name))[1]=auth.uid()::text);
DROP POLICY IF EXISTS "Admins read deposit screenshots" ON storage.objects;
CREATE POLICY "Admins read deposit screenshots" ON storage.objects FOR SELECT TO authenticated
USING (bucket_id='deposit-proofs' AND EXISTS (SELECT 1 FROM public.profiles p WHERE p.id=auth.uid() AND p.role='admin'));

DROP POLICY IF EXISTS "Players upload own withdrawal statements" ON storage.objects;
CREATE POLICY "Players upload own withdrawal statements" ON storage.objects FOR INSERT TO authenticated
WITH CHECK (bucket_id='withdrawal-bank-statements' AND (storage.foldername(name))[1]=auth.uid()::text);
DROP POLICY IF EXISTS "Players read own withdrawal statements" ON storage.objects;
CREATE POLICY "Players read own withdrawal statements" ON storage.objects FOR SELECT TO authenticated
USING (bucket_id='withdrawal-bank-statements' AND (storage.foldername(name))[1]=auth.uid()::text);
DROP POLICY IF EXISTS "Admins read withdrawal statements" ON storage.objects;
CREATE POLICY "Admins read withdrawal statements" ON storage.objects FOR SELECT TO authenticated
USING (bucket_id='withdrawal-bank-statements' AND EXISTS (SELECT 1 FROM public.profiles p WHERE p.id=auth.uid() AND p.role='admin'));

CREATE OR REPLACE FUNCTION public.submit_withdrawal_bank_statement(p_withdrawal_id uuid,p_file_path text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF p_file_path IS NULL OR split_part(p_file_path,'/',1)<>auth.uid()::text
     OR split_part(p_file_path,'/',2)<>p_withdrawal_id::text
     OR lower(right(p_file_path,4))<>'.pdf' THEN
    RAISE EXCEPTION 'Invalid statement file path';
  END IF;
  UPDATE public.withdrawals SET user_bank_statement_path=p_file_path
  WHERE id=p_withdrawal_id AND user_id=auth.uid() AND status='approved'
    AND created_at<=now()-interval '3 days' AND user_bank_statement_path IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'Upload is allowed once, only for your approved withdrawal after 3 days'; END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.submit_withdrawal_bank_statement(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_withdrawal_bank_statement(uuid,text) TO authenticated;

CREATE INDEX IF NOT EXISTS deposits_created_at_desc_idx ON public.deposits(created_at DESC);
CREATE INDEX IF NOT EXISTS withdrawals_created_at_desc_idx ON public.withdrawals(created_at DESC);
