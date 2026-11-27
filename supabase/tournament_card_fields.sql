-- Add tournament card rewards and map metadata used by Elite FF Tournaments.
ALTER TABLE public.tournaments
  ADD COLUMN IF NOT EXISTS per_kill numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS map_name text;
