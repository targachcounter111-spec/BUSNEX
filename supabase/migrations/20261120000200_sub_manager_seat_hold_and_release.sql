-- BUSNEX: allow regional Sub Managers to hold and release seats
-- only on trips whose linked route belongs to their assigned region.

CREATE OR REPLACE FUNCTION public.busnex_hold_seat(
  p_trip_id uuid,
  p_seat_number text,
  p_confirm_past_date boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid;
  v_counter_id uuid;
  v_company_id uuid;
  v_role text;
  v_trip_company_id uuid;
  v_departure_time timestamptz;
  v_route_region text;
  v_confirm_past_date boolean := COALESCE(p_confirm_past_date, false);
  v_seat public.trip_seats%ROWTYPE;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'অনুগ্রহ করে লগইন করুন';
  END IF;

  v_role := public.busnex_user_role();
  v_company_id := public.busnex_company_id();
  v_counter_id := public.busnex_counter_id();

  IF v_role IS NULL OR v_role NOT IN (
    'super_admin','company_manager','counter_operator',
    'nb_sub_manager','dhaka_sub_manager'
  ) THEN
    RAISE EXCEPTION 'আপনার Seat Hold করার অনুমতি নেই';
  END IF;

  IF v_role = 'counter_operator' THEN
    IF v_counter_id IS NULL OR v_company_id IS NULL THEN
      RAISE EXCEPTION 'আপনার Counter বা Company তথ্য পাওয়া যায়নি';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.counters c
      WHERE c.id = v_counter_id AND c.company_id = v_company_id
    ) THEN
      RAISE EXCEPTION 'আপনার Counter Assignment সঠিক নয়';
    END IF;
  END IF;

  IF v_role IN ('company_manager','nb_sub_manager','dhaka_sub_manager')
     AND v_company_id IS NULL THEN
    RAISE EXCEPTION 'আপনার Company তথ্য পাওয়া যায়নি';
  END IF;

  IF p_trip_id IS NULL OR p_seat_number IS NULL OR btrim(p_seat_number) = '' THEN
    RAISE EXCEPTION 'Trip ID এবং Seat Number দিতে হবে';
  END IF;

  SELECT t.company_id, t.departure_time, r.region
  INTO v_trip_company_id, v_departure_time, v_route_region
  FROM public.trips t
  JOIN public.routes r ON r.id = t.route_id AND r.company_id = t.company_id
  WHERE t.id = p_trip_id
    AND t.is_active = true
    AND t.status = 'scheduled'
    AND (
      v_role = 'super_admin'
      OR (
        v_role IN ('company_manager','counter_operator')
        AND t.company_id = v_company_id
      )
      OR (
        v_role IN ('nb_sub_manager','dhaka_sub_manager')
        AND t.company_id = v_company_id
        AND public.busnex_is_region_sub_manager(r.region)
      )
    );

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Trip পাওয়া যায়নি অথবা আপনার অনুমতি নেই';
  END IF;

  IF (v_departure_time AT TIME ZONE 'Asia/Dhaka')::date
     < (now() AT TIME ZONE 'Asia/Dhaka')::date
     AND NOT v_confirm_past_date THEN
    RAISE EXCEPTION 'আগের তারিখের Trip। Ticket বিক্রির আগে নিশ্চিতকরণ প্রয়োজন';
  END IF;

  SELECT * INTO v_seat
  FROM public.trip_seats
  WHERE trip_id = p_trip_id AND seat_number = btrim(p_seat_number)
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'এই Seat পাওয়া যায়নি'; END IF;
  IF v_seat.reservation_id IS NOT NULL THEN
    RAISE EXCEPTION 'এই Seat Reservation করা আছে';
  END IF;

  IF v_seat.status = 'held'
     AND v_seat.hold_until IS NOT NULL
     AND v_seat.hold_until <= now() THEN
    UPDATE public.trip_seats
    SET status = 'available', hold_until = NULL, held_by = NULL, held_counter_id = NULL
    WHERE id = v_seat.id AND reservation_id IS NULL;
    v_seat.status := 'available';
  END IF;

  IF v_seat.status <> 'available' THEN
    RAISE EXCEPTION 'এই Seat বর্তমানে Available নেই';
  END IF;

  UPDATE public.trip_seats
  SET status = 'held',
      hold_until = now() + interval '105 seconds',
      held_by = v_user_id,
      held_counter_id = CASE WHEN v_role = 'counter_operator' THEN v_counter_id ELSE NULL END
  WHERE id = v_seat.id AND reservation_id IS NULL
  RETURNING * INTO v_seat;

  IF NOT FOUND THEN RAISE EXCEPTION 'এই Seat Reservation করা আছে'; END IF;

  RETURN jsonb_build_object(
    'success', true,
    'message', 'Seat ১ মিনিট ৪৫ সেকেন্ডের জন্য Hold হয়েছে',
    'trip_id', v_seat.trip_id,
    'seat_number', v_seat.seat_number,
    'status', v_seat.status,
    'hold_until', v_seat.hold_until,
    'held_by', v_seat.held_by,
    'held_counter_id', v_seat.held_counter_id,
    'reservation_id', v_seat.reservation_id
  );
END;
$function$;

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
  v_role text;
  v_count integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Login required';
  END IF;

  v_role := public.busnex_user_role();

  IF NOT EXISTS (
    SELECT 1
    FROM public.trips t
    JOIN public.routes r ON r.id = t.route_id AND r.company_id = t.company_id
    WHERE t.id = p_trip_id
      AND (
        v_role = 'super_admin'
        OR (
          v_role IN ('company_manager','counter_operator')
          AND t.company_id = public.busnex_company_id()
        )
        OR (
          v_role IN ('nb_sub_manager','dhaka_sub_manager')
          AND t.company_id = public.busnex_company_id()
          AND public.busnex_is_region_sub_manager(r.region)
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

REVOKE ALL ON FUNCTION public.busnex_hold_seat(uuid,text,boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_hold_seat(uuid,text,boolean) TO authenticated;
REVOKE ALL ON FUNCTION public.busnex_release_own_seat_hold(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_release_own_seat_hold(uuid,text) TO authenticated;

NOTIFY pgrst, 'reload schema';
