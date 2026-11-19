-- BUSNEX: configurable per-login schedule visibility for Operator and Agent IDs.
-- Existing ID types and home/boarding region remain unchanged.

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS schedule_regions text[] NOT NULL DEFAULT ARRAY[]::text[];

-- Preserve legacy access for existing logins while converting it to explicit region lists.
UPDATE public.profiles
SET schedule_regions = CASE
  WHEN COALESCE(upper(id_type), 'OPERATOR') = 'AGENT' THEN
    CASE
      WHEN region = 'ALL' THEN ARRAY['NB','DHAKA','SB']::text[]
      WHEN region IN ('NB','DHAKA','SB') THEN ARRAY[region]::text[]
      ELSE ARRAY['NB']::text[]
    END
  WHEN region IN ('NB','DHAKA') THEN ARRAY['NB','DHAKA']::text[]
  WHEN region = 'SB' THEN ARRAY['SB']::text[]
  WHEN region = 'ALL' THEN ARRAY['NB','DHAKA','SB']::text[]
  ELSE ARRAY['NB','DHAKA']::text[]
END
WHERE role = 'counter_operator'
  AND cardinality(schedule_regions) = 0;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.profiles'::regclass
      AND conname = 'profiles_counter_schedule_regions_check'
  ) THEN
    ALTER TABLE public.profiles
      ADD CONSTRAINT profiles_counter_schedule_regions_check
      CHECK (
        role <> 'counter_operator'
        OR (
          cardinality(schedule_regions) BETWEEN 1 AND 3
          AND schedule_regions <@ ARRAY['NB','DHAKA','SB']::text[]
        )
      );
  END IF;
END $$;

-- Schedule and route visibility for every Counter Operator / Agent login
-- comes only from the explicit schedule_regions list.
DROP POLICY IF EXISTS counter_operator_trips_select ON public.trips;
CREATE POLICY counter_operator_trips_select ON public.trips
FOR SELECT TO authenticated
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
      AND r.region = ANY(p.schedule_regions)
  )
);

DROP POLICY IF EXISTS counter_operator_routes_select ON public.routes;
CREATE POLICY counter_operator_routes_select ON public.routes
FOR SELECT TO authenticated
USING (
  public.busnex_user_role() = 'counter_operator'
  AND company_id = public.busnex_company_id()
  AND EXISTS (
    SELECT 1
    FROM public.profiles p
    WHERE p.id = auth.uid()
      AND p.is_active IS DISTINCT FROM false
      AND routes.region = ANY(p.schedule_regions)
  )
);

DROP POLICY IF EXISTS counter_operator_route_stops_select ON public.route_stops;
CREATE POLICY counter_operator_route_stops_select ON public.route_stops
FOR SELECT TO authenticated
USING (
  public.busnex_user_role() = 'counter_operator'
  AND EXISTS (
    SELECT 1
    FROM public.routes r
    JOIN public.profiles p ON p.id = auth.uid()
    WHERE r.id = route_stops.route_id
      AND r.company_id = public.busnex_company_id()
      AND p.is_active IS DISTINCT FROM false
      AND r.region = ANY(p.schedule_regions)
  )
);

DROP POLICY IF EXISTS counter_operator_trip_stops_select ON public.trip_stops;
CREATE POLICY counter_operator_trip_stops_select ON public.trip_stops
FOR SELECT TO authenticated
USING (
  public.busnex_user_role() = 'counter_operator'
  AND EXISTS (
    SELECT 1
    FROM public.trips t
    JOIN public.routes r ON r.id = t.route_id
    JOIN public.profiles p ON p.id = auth.uid()
    WHERE t.id = trip_stops.trip_id
      AND t.company_id = public.busnex_company_id()
      AND r.company_id = t.company_id
      AND p.is_active IS DISTINCT FROM false
      AND r.region = ANY(p.schedule_regions)
  )
);

DROP POLICY IF EXISTS counter_operator_trip_boarding_points_select ON public.trip_boarding_points;
CREATE POLICY counter_operator_trip_boarding_points_select ON public.trip_boarding_points
FOR SELECT TO authenticated
USING (
  public.busnex_user_role() = 'counter_operator'
  AND EXISTS (
    SELECT 1
    FROM public.trips t
    JOIN public.routes r ON r.id = t.route_id
    JOIN public.profiles p ON p.id = auth.uid()
    WHERE t.id = trip_boarding_points.trip_id
      AND t.company_id = public.busnex_company_id()
      AND r.company_id = t.company_id
      AND p.is_active IS DISTINCT FROM false
      AND r.region = ANY(p.schedule_regions)
  )
);

DROP POLICY IF EXISTS counter_operator_trip_seats_select ON public.trip_seats;
CREATE POLICY counter_operator_trip_seats_select ON public.trip_seats
FOR SELECT TO authenticated
USING (
  public.busnex_user_role() = 'counter_operator'
  AND EXISTS (
    SELECT 1
    FROM public.trips t
    JOIN public.routes r ON r.id = t.route_id
    JOIN public.profiles p ON p.id = auth.uid()
    WHERE t.id = trip_seats.trip_id
      AND t.company_id = public.busnex_company_id()
      AND r.company_id = t.company_id
      AND p.is_active IS DISTINCT FROM false
      AND r.region = ANY(p.schedule_regions)
  )
);

DROP POLICY IF EXISTS counter_operator_trip_seat_layouts_select ON public.trip_seat_layouts;
CREATE POLICY counter_operator_trip_seat_layouts_select ON public.trip_seat_layouts
FOR SELECT TO authenticated
USING (
  public.busnex_user_role() = 'counter_operator'
  AND EXISTS (
    SELECT 1
    FROM public.trips t
    JOIN public.routes r ON r.id = t.route_id
    JOIN public.profiles p ON p.id = auth.uid()
    WHERE t.id = trip_seat_layouts.trip_id
      AND t.company_id = public.busnex_company_id()
      AND r.company_id = t.company_id
      AND p.is_active IS DISTINCT FROM false
      AND r.region = ANY(p.schedule_regions)
  )
);

NOTIFY pgrst, 'reload schema';
