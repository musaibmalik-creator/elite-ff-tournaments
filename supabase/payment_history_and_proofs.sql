-- Elite FF Tournaments: 12-month payment audit + private withdrawal proof storage
-- Run this complete file in Supabase SQL Editor.

ALTER TABLE public.withdrawals
  ADD COLUMN IF NOT EXISTS paid_at timestamptz,
  ADD COLUMN IF NOT EXISTS payment_proof_path text;

-- Keep historical approved rows searchable; paid_at is backfilled from creation time
-- only where no explicit payout timestamp exists.
UPDATE public.withdrawals
SET paid_at = created_at
WHERE status = 'approved' AND paid_at IS NULL;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'withdrawal-proofs',
  'withdrawal-proofs',
  false,
  5242880,
  ARRAY['image/jpeg','image/png','image/webp','application/pdf']
)
ON CONFLICT (id) DO UPDATE
SET public = false,
    file_size_limit = 5242880,
    allowed_mime_types = ARRAY['image/jpeg','image/png','image/webp','application/pdf'];

DROP POLICY IF EXISTS "Admins manage withdrawal proof files" ON storage.objects;
CREATE POLICY "Admins manage withdrawal proof files"
ON storage.objects
FOR ALL
TO authenticated
USING (
  bucket_id = 'withdrawal-proofs'
  AND EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = auth.uid() AND p.role = 'admin'
  )
)
WITH CHECK (
  bucket_id = 'withdrawal-proofs'
  AND EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = auth.uid() AND p.role = 'admin'
  )
);

DROP POLICY IF EXISTS "Users view own withdrawal proof files" ON storage.objects;
CREATE POLICY "Users view own withdrawal proof files"
ON storage.objects
FOR SELECT
TO authenticated
USING (
  bucket_id = 'withdrawal-proofs'
  AND (storage.foldername(name))[1] = auth.uid()::text
);

CREATE INDEX IF NOT EXISTS withdrawals_created_at_desc_idx
ON public.withdrawals (created_at DESC);

CREATE INDEX IF NOT EXISTS deposits_created_at_desc_idx
ON public.deposits (created_at DESC);
