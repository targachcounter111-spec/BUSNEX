-- BUSNEX: Enable NB/Dhaka Sub Managers to load reservation counters
-- and release only their own temporary holds on trips in their assigned region.

CREATE OR REPLACE FUNCTION public.busnex_get_reservation_booking_counters(p_company_id uuid)
RETURNS TABLE(counter_id uuid, counter_name text, counter_address text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_role text;
  v_company_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Login required';
  END IF;

  v_role := public.busnex_user_role();
  v_company_id := public.busnex_company_id();

  IF v_role = 'company_manager' THEN
    IF v_company_id IS NULL OR (p_company_id IS NOT NULL AND p_company_id <> v_company_id) THEN
      RAISE EXCEPTION 'অন্য Company-এর Counter দেখা যাবে না';
    END IF;
  ELSIF v_role = 'super_admin' THEN
    IF p_company_id IS NULL THEN
      RAISE EXCEPTION 'Company নির্বাচন করুন';
    END IF;
    v_company_id := p_company_id;
  ELSIF v_role IN ('nb_sub_manager', 'dhaka_sub_manager') THEN
    IF v_company_id IS NULL
       OR (p_company_id IS NOT NULL AND p_company_id <> v_company_id) THEN
      RAISE EXCEPTION 'অন্য Company-এর Counter দেখা যাবে না';
    END IF;
  ELSE
    RAISE EXCEPTION 'Not authorized';
  END IF;

  RETURN QUERY
    SELECT c.id, c.name, c.address
    FROM public.counters c
    WHERE c.company_id = v_company_id
      AND c.is_active = true
      AND (
        v_role IN ('company_manager', 'super_admin')
        OR (
          v_role = 'nb_sub_manager'
          AND c.region = 'NB'
          AND public.busnex_user_region() = 'NB'
        )
        OR (
          v_role = 'dhaka_sub_manager'
          AND c.region = 'DHAKA'
          AND public.busnex_user_region() = 'DHAKA'
        )
      )
    ORDER BY c.name;
END;
$function$;

CREATE OR REPLACE FUNCTION public.busnex_release_own_trip_seat_holds(
  p_trip_id uuid
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_count integer;
  v_role text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Login required';
  END IF;

  v_role := public.busnex_user_role();

  IF NOT EXISTS (
    SELECT 1
    FROM public.trips t
    JOIN public.routes r ON r.id = t.route_id
    WHERE t.id = p_trip_id
      AND (
        v_role = 'super_admin'
        OR (
          v_role = 'company_manager'
          AND t.company_id = public.busnex_company_id()
        )
        OR (
          v_role = 'counter_operator'
          AND t.company_id = public.busnex_company_id()
        )
        OR (
          v_role = 'nb_sub_manager'
          AND t.company_id = public.busnex_company_id()
          AND r.company_id = t.company_id
          AND public.busnex_is_region_sub_manager(r.region)
        )
        OR (
          v_role = 'dhaka_sub_manager'
          AND t.company_id = public.busnex_company_id()
          AND r.company_id = t.company_id
          AND public.busnex_is_region_sub_manager(r.region)
        )
      )
  ) THEN
    RAISE EXCEPTION 'এই Trip-এর Hold পরিষ্কার করার অনুমতি নেই';
  END IF;

  UPDATE public.trip_seats ts
  SET status = 'available',
      hold_until = NULL,
      held_by = NULL,
      held_counter_id = NULL
  WHERE ts.trip_id = p_trip_id
    AND ts.status = 'held'
    AND ts.reservation_id IS NULL
    AND ts.held_by = auth.uid();

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

REVOKE ALL ON FUNCTION public.busnex_get_reservation_booking_counters(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_get_reservation_booking_counters(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.busnex_release_own_trip_seat_holds(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_release_own_trip_seat_holds(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
