-- BUSNEX: Allow NB/Dhaka Sub Managers to create company buses and seat layouts.
-- Access is restricted to the authenticated user's own company.

DROP POLICY IF EXISTS buses_sub_manager_insert ON public.buses;
CREATE POLICY buses_sub_manager_insert
ON public.buses
FOR INSERT
TO authenticated
WITH CHECK (
  company_id = public.busnex_company_id()
  AND public.busnex_user_role() IN ('nb_sub_manager','dhaka_sub_manager')
);

DROP POLICY IF EXISTS bus_seat_layouts_sub_manager_select ON public.bus_seat_layouts;
CREATE POLICY bus_seat_layouts_sub_manager_select
ON public.bus_seat_layouts
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.buses b
    WHERE b.id = bus_seat_layouts.bus_id
      AND b.company_id = public.busnex_company_id()
  )
  AND public.busnex_user_role() IN ('nb_sub_manager','dhaka_sub_manager')
);

DROP POLICY IF EXISTS bus_seat_layouts_sub_manager_insert ON public.bus_seat_layouts;
CREATE POLICY bus_seat_layouts_sub_manager_insert
ON public.bus_seat_layouts
FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM public.buses b
    WHERE b.id = bus_seat_layouts.bus_id
      AND b.company_id = public.busnex_company_id()
  )
  AND public.busnex_user_role() IN ('nb_sub_manager','dhaka_sub_manager')
);
