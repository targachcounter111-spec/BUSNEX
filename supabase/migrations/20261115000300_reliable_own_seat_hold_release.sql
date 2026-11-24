-- BUSNEX: reliable release of the current user's temporary seat holds.
-- Refresh/re-entry releases only holds owned by auth.uid(); other counters are untouched.

CREATE OR REPLACE FUNCTION public.busnex_release_own_seat_hold(
  p_trip_id uuid,
  p_seat_number text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_count integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Login required';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.trips t
    WHERE t.id = p_trip_id
      AND (
        public.busnex_user_role() = 'super_admin'
        OR (
          public.busnex_user_role() IN ('company_manager','counter_operator')
          AND t.company_id = public.busnex_company_id()
        )
      )
  ) THEN
    RAISE EXCEPTION 'এই Trip-এর Hold ছাড়ার অনুমতি নেই';
  END IF;

  UPDATE public.trip_seats ts
  SET status = 'available',
      hold_until = NULL,
      held_by = NULL,
      held_counter_id = NULL
  WHERE ts.trip_id = p_trip_id
    AND ts.seat_number = btrim(p_seat_number)
    AND ts.status = 'held'
    AND ts.reservation_id IS NULL
    AND ts.held_by = auth.uid();

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count = 1;
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
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Login required';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.trips t
    WHERE t.id = p_trip_id
      AND (
        public.busnex_user_role() = 'super_admin'
        OR (
          public.busnex_user_role() IN ('company_manager','counter_operator')
          AND t.company_id = public.busnex_company_id()
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

REVOKE ALL ON FUNCTION public.busnex_release_own_seat_hold(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_release_own_seat_hold(uuid,text) TO authenticated;
REVOKE ALL ON FUNCTION public.busnex_release_own_trip_seat_holds(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_release_own_trip_seat_holds(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
