-- BUSNEX: region-scoped NB and Dhaka Sub Manager roles.
-- NB Sub Manager can access NB only; Dhaka Sub Manager can access DHAKA only.
-- Existing Company Manager and Super Admin policies remain in place.

DO $$
DECLARE c record;
BEGIN
  FOR c IN
    SELECT conname
    FROM pg_constraint
    WHERE conrelid = 'public.profiles'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%role = ANY%'
  LOOP
    EXECUTE format('ALTER TABLE public.profiles DROP CONSTRAINT %I', c.conname);
  END LOOP;
END $$;

ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_role_check
  CHECK (role = ANY (ARRAY[
    'super_admin'::text,
    'company_manager'::text,
    'counter_operator'::text,
    'nb_sub_manager'::text,
    'dhaka_sub_manager'::text
  ]));

ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_sub_manager_region_check
  CHECK (
    (role <> 'nb_sub_manager' OR region = 'NB')
    AND (role <> 'dhaka_sub_manager' OR region = 'DHAKA')
  );

CREATE OR REPLACE FUNCTION public.busnex_is_region_sub_manager(p_region text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.profiles p
    WHERE p.id = auth.uid()
      AND p.is_active IS DISTINCT FROM false
      AND (
        (p.role = 'nb_sub_manager' AND p.region = 'NB' AND p_region = 'NB')
        OR
        (p.role = 'dhaka_sub_manager' AND p.region = 'DHAKA' AND p_region = 'DHAKA')
      )
  )
$$;

REVOKE ALL ON FUNCTION public.busnex_is_region_sub_manager(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_is_region_sub_manager(text) TO authenticated;

-- Remove broad company-wide SELECT policies; manager/admin policies remain.
DROP POLICY IF EXISTS routes_select ON public.routes;
DROP POLICY IF EXISTS busnex_routes_select_company ON public.routes;
DROP POLICY IF EXISTS trips_select ON public.trips;
DROP POLICY IF EXISTS busnex_trips_select_company ON public.trips;
DROP POLICY IF EXISTS route_stops_select_by_company ON public.route_stops;
DROP POLICY IF EXISTS trip_stops_select_by_company ON public.trip_stops;
DROP POLICY IF EXISTS busnex_boarding_select ON public.trip_boarding_points;
DROP POLICY IF EXISTS trip_seats_select ON public.trip_seats;

-- Routes: sub-managers can only see/create/edit/delete their assigned region.
CREATE POLICY routes_sub_manager_select ON public.routes
FOR SELECT TO authenticated
USING (
  company_id = public.busnex_company_id()
  AND public.busnex_is_region_sub_manager(region)
);

CREATE POLICY routes_sub_manager_insert ON public.routes
FOR INSERT TO authenticated
WITH CHECK (
  company_id = public.busnex_company_id()
  AND public.busnex_is_region_sub_manager(region)
);

CREATE POLICY routes_sub_manager_update ON public.routes
FOR UPDATE TO authenticated
USING (
  company_id = public.busnex_company_id()
  AND public.busnex_is_region_sub_manager(region)
)
WITH CHECK (
  company_id = public.busnex_company_id()
  AND public.busnex_is_region_sub_manager(region)
);

CREATE POLICY routes_sub_manager_delete ON public.routes
FOR DELETE TO authenticated
USING (
  company_id = public.busnex_company_id()
  AND public.busnex_is_region_sub_manager(region)
);

-- Trips inherit their region from the linked route, preventing forged trip regions.
CREATE POLICY trips_sub_manager_select ON public.trips
FOR SELECT TO authenticated
USING (
  company_id = public.busnex_company_id()
  AND EXISTS (
    SELECT 1 FROM public.routes r
    WHERE r.id = trips.route_id
      AND r.company_id = trips.company_id
      AND public.busnex_is_region_sub_manager(r.region)
  )
);

CREATE POLICY trips_sub_manager_insert ON public.trips
FOR INSERT TO authenticated
WITH CHECK (
  company_id = public.busnex_company_id()
  AND EXISTS (
    SELECT 1 FROM public.routes r
    WHERE r.id = trips.route_id
      AND r.company_id = trips.company_id
      AND public.busnex_is_region_sub_manager(r.region)
  )
);

CREATE POLICY trips_sub_manager_update ON public.trips
FOR UPDATE TO authenticated
USING (
  company_id = public.busnex_company_id()
  AND EXISTS (
    SELECT 1 FROM public.routes r
    WHERE r.id = trips.route_id
      AND r.company_id = trips.company_id
      AND public.busnex_is_region_sub_manager(r.region)
  )
)
WITH CHECK (
  company_id = public.busnex_company_id()
  AND EXISTS (
    SELECT 1 FROM public.routes r
    WHERE r.id = trips.route_id
      AND r.company_id = trips.company_id
      AND public.busnex_is_region_sub_manager(r.region)
  )
);

CREATE POLICY trips_sub_manager_delete ON public.trips
FOR DELETE TO authenticated
USING (
  company_id = public.busnex_company_id()
  AND EXISTS (
    SELECT 1 FROM public.routes r
    WHERE r.id = trips.route_id
      AND r.company_id = trips.company_id
      AND public.busnex_is_region_sub_manager(r.region)
  )
);

-- Route stops inherit the region from their route.
CREATE POLICY route_stops_sub_manager_select ON public.route_stops
FOR SELECT TO authenticated
USING (EXISTS (
  SELECT 1 FROM public.routes r
  WHERE r.id = route_stops.route_id
    AND r.company_id = public.busnex_company_id()
    AND public.busnex_is_region_sub_manager(r.region)
));

CREATE POLICY route_stops_sub_manager_insert ON public.route_stops
FOR INSERT TO authenticated
WITH CHECK (EXISTS (
  SELECT 1 FROM public.routes r
  WHERE r.id = route_stops.route_id
    AND r.company_id = public.busnex_company_id()
    AND public.busnex_is_region_sub_manager(r.region)
));

CREATE POLICY route_stops_sub_manager_update ON public.route_stops
FOR UPDATE TO authenticated
USING (EXISTS (
  SELECT 1 FROM public.routes r
  WHERE r.id = route_stops.route_id
    AND r.company_id = public.busnex_company_id()
    AND public.busnex_is_region_sub_manager(r.region)
))
WITH CHECK (EXISTS (
  SELECT 1 FROM public.routes r
  WHERE r.id = route_stops.route_id
    AND r.company_id = public.busnex_company_id()
    AND public.busnex_is_region_sub_manager(r.region)
));

CREATE POLICY route_stops_sub_manager_delete ON public.route_stops
FOR DELETE TO authenticated
USING (EXISTS (
  SELECT 1 FROM public.routes r
  WHERE r.id = route_stops.route_id
    AND r.company_id = public.busnex_company_id()
    AND public.busnex_is_region_sub_manager(r.region)
));

-- Trip stops and boarding points inherit access from their parent trip's route.
CREATE POLICY trip_stops_sub_manager_select ON public.trip_stops
FOR SELECT TO authenticated
USING (EXISTS (
  SELECT 1 FROM public.trips t JOIN public.routes r ON r.id = t.route_id
  WHERE t.id = trip_stops.trip_id
    AND t.company_id = public.busnex_company_id()
    AND public.busnex_is_region_sub_manager(r.region)
));

CREATE POLICY trip_stops_sub_manager_insert ON public.trip_stops
FOR INSERT TO authenticated
WITH CHECK (EXISTS (
  SELECT 1 FROM public.trips t JOIN public.routes r ON r.id = t.route_id
  WHERE t.id = trip_stops.trip_id
    AND t.company_id = public.busnex_company_id()
    AND public.busnex_is_region_sub_manager(r.region)
));

CREATE POLICY trip_stops_sub_manager_update ON public.trip_stops
FOR UPDATE TO authenticated
USING (EXISTS (
  SELECT 1 FROM public.trips t JOIN public.routes r ON r.id = t.route_id
  WHERE t.id = trip_stops.trip_id
    AND t.company_id = public.busnex_company_id()
    AND public.busnex_is_region_sub_manager(r.region)
))
WITH CHECK (EXISTS (
  SELECT 1 FROM public.trips t JOIN public.routes r ON r.id = t.route_id
  WHERE t.id = trip_stops.trip_id
    AND t.company_id = public.busnex_company_id()
    AND public.busnex_is_region_sub_manager(r.region)
));

CREATE POLICY trip_stops_sub_manager_delete ON public.trip_stops
FOR DELETE TO authenticated
USING (EXISTS (
  SELECT 1 FROM public.trips t JOIN public.routes r ON r.id = t.route_id
  WHERE t.id = trip_stops.trip_id
    AND t.company_id = public.busnex_company_id()
    AND public.busnex_is_region_sub_manager(r.region)
));

CREATE POLICY trip_boarding_sub_manager_select ON public.trip_boarding_points
FOR SELECT TO authenticated
USING (EXISTS (
  SELECT 1 FROM public.trips t JOIN public.routes r ON r.id = t.route_id
  WHERE t.id = trip_boarding_points.trip_id
    AND t.company_id = public.busnex_company_id()
    AND public.busnex_is_region_sub_manager(r.region)
));

CREATE POLICY trip_boarding_sub_manager_insert ON public.trip_boarding_points
FOR INSERT TO authenticated
WITH CHECK (EXISTS (
  SELECT 1 FROM public.trips t JOIN public.routes r ON r.id = t.route_id
  WHERE t.id = trip_boarding_points.trip_id
    AND t.company_id = public.busnex_company_id()
    AND public.busnex_is_region_sub_manager(r.region)
));

CREATE POLICY trip_boarding_sub_manager_update ON public.trip_boarding_points
FOR UPDATE TO authenticated
USING (EXISTS (
  SELECT 1 FROM public.trips t JOIN public.routes r ON r.id = t.route_id
  WHERE t.id = trip_boarding_points.trip_id
    AND t.company_id = public.busnex_company_id()
    AND public.busnex_is_region_sub_manager(r.region)
))
WITH CHECK (EXISTS (
  SELECT 1 FROM public.trips t JOIN public.routes r ON r.id = t.route_id
  WHERE t.id = trip_boarding_points.trip_id
    AND t.company_id = public.busnex_company_id()
    AND public.busnex_is_region_sub_manager(r.region)
));

CREATE POLICY trip_boarding_sub_manager_delete ON public.trip_boarding_points
FOR DELETE TO authenticated
USING (EXISTS (
  SELECT 1 FROM public.trips t JOIN public.routes r ON r.id = t.route_id
  WHERE t.id = trip_boarding_points.trip_id
    AND t.company_id = public.busnex_company_id()
    AND public.busnex_is_region_sub_manager(r.region)
));

-- Sub-managers need buses and counters for schedule/Counter-ID management.
CREATE POLICY buses_sub_manager_select ON public.buses
FOR SELECT TO authenticated
USING (
  company_id = public.busnex_company_id()
  AND public.busnex_user_role() IN ('nb_sub_manager','dhaka_sub_manager')
);

CREATE POLICY counters_sub_manager_select ON public.counters
FOR SELECT TO authenticated
USING (
  company_id = public.busnex_company_id()
  AND public.busnex_user_role() IN ('nb_sub_manager','dhaka_sub_manager')
);

CREATE POLICY profiles_sub_manager_select ON public.profiles
FOR SELECT TO authenticated
USING (
  company_id = public.busnex_company_id()
  AND region = (
    SELECT p.region FROM public.profiles p WHERE p.id = auth.uid()
  )
  AND public.busnex_user_role() IN ('nb_sub_manager','dhaka_sub_manager')
);
