-- BUSNEX schedule visibility for regional counter operators.
-- NB operator: NB + DHAKA trips. DHAKA operator: DHAKA trips only.
-- This modifies SELECT-only policies and does not change write permissions.

DROP POLICY IF EXISTS counter_operator_trips_select ON public.trips;
CREATE POLICY counter_operator_trips_select
ON public.trips
FOR SELECT
TO authenticated
USING (
  public.busnex_user_role() = 'counter_operator'
  AND company_id = public.busnex_company_id()
  AND EXISTS (
    SELECT 1
    FROM public.profiles p
    JOIN public.routes r ON r.id = trips.route_id
    WHERE p.id = auth.uid()
      AND p.is_active IS DISTINCT FROM false
      AND r.company_id = trips.company_id
      AND (
        (p.region = 'NB' AND r.region IN ('NB','DHAKA'))
        OR (p.region = 'DHAKA' AND r.region = 'DHAKA')
      )
  )
);

DROP POLICY IF EXISTS counter_operator_routes_select ON public.routes;
CREATE POLICY counter_operator_routes_select
ON public.routes
FOR SELECT
TO authenticated
USING (
  public.busnex_user_role() = 'counter_operator'
  AND company_id = public.busnex_company_id()
  AND EXISTS (
    SELECT 1
    FROM public.profiles p
    WHERE p.id = auth.uid()
      AND p.is_active IS DISTINCT FROM false
      AND (
        (p.region = 'NB' AND routes.region IN ('NB','DHAKA'))
        OR (p.region = 'DHAKA' AND routes.region = 'DHAKA')
      )
  )
);

NOTIFY pgrst, 'reload schema';
