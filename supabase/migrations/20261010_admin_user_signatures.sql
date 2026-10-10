-- Run this migration in Supabase SQL Editor before deploying the updated portal.
-- Signature PNGs are stored as data URLs; admin API writes them server-side only.
ALTER TABLE public.user_profiles
ADD COLUMN IF NOT EXISTS signature_data_url text;

COMMENT ON COLUMN public.user_profiles.signature_data_url IS
'Authorized PNG signature data URL used in approved RA Bill printouts. Managed through the protected System Admin API.';
