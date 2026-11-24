-- BUSNEX: Allow NB/Dhaka regional Sub Managers to create missing trip-seat inventory
-- only for trips whose route belongs to their assigned region and company.

DROP POLICY IF EXISTS trip_seats_sub_manager_insert ON public.trip_seats;

CREATE POLICY trip_seats_sub_manager_insert
ON public.trip_seats
FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM public.trips t
    JOIN public.routes r ON r.id = t.route_id
    WHERE t.id = trip_seats.trip_id
      AND t.company_id = public.busnex_company_id()
      AND r.company_id = t.company_id
      AND public.busnex_is_region_sub_manager(r.region)
  )
);

GRANT EXECUTE ON FUNCTION public.busnex_sync_trip_seats(uuid, jsonb)
TO authenticated;
