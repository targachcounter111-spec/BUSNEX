-- Enforce maintenance mode even when another permissive policy grants writes.
-- Restrictive policies are ANDed with all permissive policies, closing the OR-policy bypass.
DO $$
DECLARE
  v_table text;
BEGIN
  FOREACH v_table IN ARRAY ARRAY[
    'bus_seat_layouts',
    'buses',
    'counters',
    'profile_assigned_routes',
    'route_stops',
    'routes',
    'trip_boarding_points',
    'trip_seat_layouts',
    'trip_stops',
    'trips'
  ]
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS busnex_maintenance_restrict_insert ON public.%I', v_table);
    EXECUTE format('DROP POLICY IF EXISTS busnex_maintenance_restrict_update ON public.%I', v_table);
    EXECUTE format('DROP POLICY IF EXISTS busnex_maintenance_restrict_delete ON public.%I', v_table);

    EXECUTE format(
      'CREATE POLICY busnex_maintenance_restrict_insert ON public.%I AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (NOT public.busnex_is_maintenance_mode() OR public.busnex_user_role() = ''super_admin'')',
      v_table
    );
    EXECUTE format(
      'CREATE POLICY busnex_maintenance_restrict_update ON public.%I AS RESTRICTIVE FOR UPDATE TO authenticated USING (NOT public.busnex_is_maintenance_mode() OR public.busnex_user_role() = ''super_admin'') WITH CHECK (NOT public.busnex_is_maintenance_mode() OR public.busnex_user_role() = ''super_admin'')',
      v_table
    );
    EXECUTE format(
      'CREATE POLICY busnex_maintenance_restrict_delete ON public.%I AS RESTRICTIVE FOR DELETE TO authenticated USING (NOT public.busnex_is_maintenance_mode() OR public.busnex_user_role() = ''super_admin'')',
      v_table
    );
  END LOOP;
END
$$;

NOTIFY pgrst, 'reload schema';
