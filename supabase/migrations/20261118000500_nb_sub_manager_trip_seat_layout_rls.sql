-- BUSNEX: Allow regional Sub Managers to save Trip Seat Layout
-- only for trips belonging to their own company and assigned route region.

DROP POLICY IF EXISTS trip_seat_layouts_sub_manager_select ON public.trip_seat_layouts;
CREATE POLICY trip_seat_layouts_sub_manager_select
ON public.trip_seat_layouts
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.trips t
    JOIN public.routes r ON r.id = t.route_id
    WHERE t.id = trip_seat_layouts.trip_id
      AND t.company_id = public.busnex_company_id()
      AND r.company_id = t.company_id
      AND public.busnex_is_region_sub_manager(r.region)
  )
);

DROP POLICY IF EXISTS trip_seat_layouts_sub_manager_insert ON public.trip_seat_layouts;
CREATE POLICY trip_seat_layouts_sub_manager_insert
ON public.trip_seat_layouts
FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM public.trips t
    JOIN public.routes r ON r.id = t.route_id
    WHERE t.id = trip_seat_layouts.trip_id
      AND t.company_id = public.busnex_company_id()
      AND r.company_id = t.company_id
      AND public.busnex_is_region_sub_manager(r.region)
  )
);

DROP POLICY IF EXISTS trip_seat_layouts_sub_manager_update ON public.trip_seat_layouts;
CREATE POLICY trip_seat_layouts_sub_manager_update
ON public.trip_seat_layouts
FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.trips t
    JOIN public.routes r ON r.id = t.route_id
    WHERE t.id = trip_seat_layouts.trip_id
      AND t.company_id = public.busnex_company_id()
      AND r.company_id = t.company_id
      AND public.busnex_is_region_sub_manager(r.region)
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM public.trips t
    JOIN public.routes r ON r.id = t.route_id
    WHERE t.id = trip_seat_layouts.trip_id
      AND t.company_id = public.busnex_company_id()
      AND r.company_id = t.company_id
      AND public.busnex_is_region_sub_manager(r.region)
  )
);
