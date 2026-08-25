begin;

-- Supabase commonly installs pgcrypto in the extensions schema.  The reward
-- grant function must be able to resolve digest() when called by the
-- checkpoint RPC under SECURITY DEFINER.
alter function public.grant_out_of_match_reward(text, uuid, text, integer, numeric)
    set search_path = public, extensions;

commit;