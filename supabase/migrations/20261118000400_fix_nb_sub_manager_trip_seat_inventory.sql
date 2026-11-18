-- BUSNEX: Permit regional Sub Managers to create trip seat inventory
-- while enforcing strict company and route-region boundaries.
-- This updates only the existing two-argument RPC used by the schedule UI.

DO $migration$
DECLARE
  v_definition text;
  v_updated text;
  v_role_guard text := $old$IF v_role NOT IN ('super_admin', 'company_manager') THEN$old$;
  v_new_role_guard text := $new$IF v_role NOT IN ('super_admin', 'company_manager', 'nb_sub_manager', 'dhaka_sub_manager') THEN$new$;
  v_company_guard text := $old$
    IF v_role = 'company_manager'
       AND v_trip_company IS DISTINCT FROM v_user_company THEN
        RAISE EXCEPTION 'You cannot manage another company trip';
    END IF;

    SELECT b.company_id$old$;
  v_new_company_guard text := $new$
    IF v_role = 'company_manager'
       AND v_trip_company IS DISTINCT FROM v_user_company THEN
        RAISE EXCEPTION 'You cannot manage another company trip';
    END IF;

    IF v_role IN ('nb_sub_manager', 'dhaka_sub_manager')
       AND (
         v_trip_company IS DISTINCT FROM v_user_company
         OR NOT EXISTS (
           SELECT 1
           FROM public.trips t
           JOIN public.routes r ON r.id = t.route_id
           WHERE t.id = p_trip_id
             AND t.company_id = v_user_company
             AND r.company_id = t.company_id
             AND public.busnex_is_region_sub_manager(r.region)
         )
       ) THEN
        RAISE EXCEPTION 'You cannot manage a trip outside your assigned region/company';
    END IF;

    SELECT b.company_id$new$;
BEGIN
  SELECT pg_get_functiondef(
    'public.busnex_sync_trip_seats(uuid,jsonb)'::regprocedure
  ) INTO v_definition;

  IF position(v_role_guard IN v_definition) = 0 THEN
    RAISE EXCEPTION 'Expected role guard was not found; no function was changed';
  END IF;

  IF position(v_company_guard IN v_definition) = 0 THEN
    RAISE EXCEPTION 'Expected company guard was not found; no function was changed';
  END IF;

  v_updated := replace(v_definition, v_role_guard, v_new_role_guard);
  v_updated := replace(v_updated, v_company_guard, v_new_company_guard);

  IF v_updated = v_definition THEN
    RAISE EXCEPTION 'Function definition was not changed; migration stopped';
  END IF;

  EXECUTE v_updated;
END
$migration$;

GRANT EXECUTE ON FUNCTION public.busnex_sync_trip_seats(uuid, jsonb)
TO authenticated;
