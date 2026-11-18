-- BUSNEX: Allow regional Sub Managers to expire stale holds only on trips in their assigned region.
-- Keep the existing company/role checks and only release genuinely expired, unreserved holds.

CREATE OR REPLACE FUNCTION public.busnex_expire_trip_seat_holds(p_trip_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_role text;
  v_company_id uuid;
  v_trip_company_id uuid;
  v_region text;
  v_count integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Login required';
  END IF;

  v_role := public.busnex_user_role();
  v_company_id := public.busnex_company_id();

  SELECT t.company_id, r.region
  INTO v_trip_company_id, v_region
  FROM public.trips t
  JOIN public.routes r ON r.id = t.route_id
  WHERE t.id = p_trip_id
    AND r.company_id = t.company_id;

  IF v_trip_company_id IS NULL THEN
    RAISE EXCEPTION 'Trip পাওয়া যায়নি';
  END IF;

  IF NOT (
    v_role = 'super_admin'
    OR (
      v_role IN ('company_manager', 'counter_operator')
      AND v_company_id IS NOT NULL
      AND v_trip_company_id = v_company_id
    )
    OR (
      v_role IN ('nb_sub_manager', 'dhaka_sub_manager')
      AND v_company_id IS NOT NULL
      AND v_trip_company_id = v_company_id
      AND public.busnex_is_region_sub_manager(v_region)
    )
  ) THEN
    RAISE EXCEPTION 'অনুমতি নেই';
  END IF;

  UPDATE public.trip_seats
  SET status = 'available',
      hold_until = NULL,
      held_by = NULL,
      held_counter_id = NULL
  WHERE trip_id = p_trip_id
    AND status = 'held'
    AND reservation_id IS NULL
    AND hold_until IS NOT NULL
    AND hold_until <= now();

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

REVOKE ALL ON FUNCTION public.busnex_expire_trip_seat_holds(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_expire_trip_seat_holds(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
