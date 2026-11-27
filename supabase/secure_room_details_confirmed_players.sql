-- Room details must only be readable by fully confirmed players or admins.
-- This replaces existing SELECT policies for this table so an older
-- captain/any-player policy cannot continue granting room access.

ALTER TABLE public.tournament_room_details ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE
  existing_policy record;
BEGIN
  FOR existing_policy IN
    SELECT policyname
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'tournament_room_details'
      AND cmd = 'SELECT'
  LOOP
    EXECUTE format(
      'DROP POLICY IF EXISTS %I ON public.tournament_room_details',
      existing_policy.policyname
    );
  END LOOP;
END
$$;

CREATE POLICY "Admins and confirmed players can view room details"
ON public.tournament_room_details
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.profiles profile
    WHERE profile.id = auth.uid()
      AND profile.role = 'admin'
  )
  OR EXISTS (
    SELECT 1
    FROM public.players player
    WHERE player.tournament_id = tournament_room_details.tournament_id
      AND player.user_id = auth.uid()
      AND player.status = 'confirmed'
  )
);

-- Keep the existing admin-only ALL policy in place for room management.
