-- BUSNEX: allow Dhaka Sub Managers to create counters only in DHAKA.
-- Preserve the existing NB Sub Manager insert policy and all manager/admin policies.

DROP POLICY IF EXISTS counters_dhaka_sub_manager_insert ON public.counters;
CREATE POLICY counters_dhaka_sub_manager_insert
ON public.counters
FOR INSERT
TO authenticated
WITH CHECK (
  company_id = public.busnex_company_id()
  AND region = 'DHAKA'
  AND public.busnex_user_role() = 'dhaka_sub_manager'
  AND public.busnex_user_region() = 'DHAKA'
);

NOTIFY pgrst, 'reload schema';
