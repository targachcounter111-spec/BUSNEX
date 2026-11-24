-- BUSNEX: restore read-only schedule visibility for Counter Operators.
-- Counter IDs may read only their own company's active schedule and the
-- related route, stop, bus and seat-layout data required by Ticket Booking.

BEGIN;

DROP POLICY IF EXISTS counter_operator_trips_select ON public.trips;
CREATE POLICY counter_operator_trips_select ON public.trips
FOR SELECT TO authenticated
USING (
  public.busnex_user_role() = 'counter_operator'
  AND company_id = public.busnex_company_id()
);

DROP POLICY IF EXISTS counter_operator_routes_select ON public.routes;
CREATE POLICY counter_operator_routes_select ON public.routes
FOR SELECT TO authenticated
USING (
  public.busnex_user_role() = 'counter_operator'
  AND company_id = public.busnex_company_id()
);

DROP POLICY IF EXISTS counter_operator_buses_select ON public.buses;
CREATE POLICY counter_operator_buses_select ON public.buses
FOR SELECT TO authenticated
USING (
  public.busnex_user_role() = 'counter_operator'
  AND company_id = public.busnex_company_id()
);

DROP POLICY IF EXISTS counter_operator_trip_stops_select ON public.trip_stops;
CREATE POLICY counter_operator_trip_stops_select ON public.trip_stops
FOR SELECT TO authenticated
USING (
  public.busnex_user_role() = 'counter_operator'
  AND EXISTS (
    SELECT 1
    FROM public.trips t
    WHERE t.id = trip_stops.trip_id
      AND t.company_id = public.busnex_company_id()
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
    WHERE t.id = trip_boarding_points.trip_id
      AND t.company_id = public.busnex_company_id()
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
    WHERE t.id = trip_seats.trip_id
      AND t.company_id = public.busnex_company_id()
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
    WHERE t.id = trip_seat_layouts.trip_id
      AND t.company_id = public.busnex_company_id()
  )
);

COMMIT;
