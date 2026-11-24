-- BUSNEX: safely release a user's own temporary seat hold and expire timed-out holds.
-- Never release another user's/counter's active hold or a reservation-linked seat.

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
  v_counter_id uuid;
  v_count integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Login required';
  END IF;

  v_counter_id := public.busnex_counter_id();

  UPDATE public.trip_seats AS ts
  SET status = 'available',
      hold_until = NULL,
      held_by = NULL,
      held_counter_id = NULL
  WHERE ts.trip_id = p_trip_id
    AND ts.seat_number = btrim(p_seat_number)
    AND ts.status = 'held'
    AND ts.reservation_id IS NULL
    AND ts.held_by = auth.uid()
    AND ts.held_counter_id IS NOT DISTINCT FROM v_counter_id
    AND ts.hold_until > now();

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count = 1;
END;
$function$;

CREATE OR REPLACE FUNCTION public.busnex_expire_trip_seat_holds(
  p_trip_id uuid
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_role text;
  v_company_id uuid;
  v_trip_company_id uuid;
  v_count integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Login required';
  END IF;

  v_role := public.busnex_user_role();
  v_company_id := public.busnex_company_id();

  SELECT t.company_id
  INTO v_trip_company_id
  FROM public.trips AS t
  WHERE t.id = p_trip_id;

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
  ) THEN
    RAISE EXCEPTION 'এই Trip-এর Hold পরিষ্কার করার অনুমতি নেই';
  END IF;

  UPDATE public.trip_seats AS ts
  SET status = 'available',
      hold_until = NULL,
      held_by = NULL,
      held_counter_id = NULL
  WHERE ts.trip_id = p_trip_id
    AND ts.status = 'held'
    AND ts.reservation_id IS NULL
    AND ts.hold_until IS NOT NULL
    AND ts.hold_until <= now();

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

REVOKE ALL ON FUNCTION public.busnex_release_own_seat_hold(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_release_own_seat_hold(uuid, text) TO authenticated;
REVOKE ALL ON FUNCTION public.busnex_expire_trip_seat_holds(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_expire_trip_seat_holds(uuid) TO authenticated;
