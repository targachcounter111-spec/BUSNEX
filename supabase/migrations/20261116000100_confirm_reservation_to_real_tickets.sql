-- BUSNEX: convert an active reservation into real sold tickets atomically.
-- Every reserved seat becomes a tickets row and its trip_seats row becomes sold.
-- Any failure rolls back the entire function call; no partial group ticket issue.

CREATE OR REPLACE FUNCTION public.busnex_confirm_reservation(
  p_reservation_id uuid,
  p_confirm_past_date boolean DEFAULT false
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_res public.ticket_reservations%ROWTYPE;
  v_trip public.trips%ROWTYPE;
  v_res_seat public.ticket_reservation_seats%ROWTYPE;
  v_role text;
  v_company_id uuid;
  v_counter_id uuid;
  v_counter_company_id uuid;
  v_seat_count integer;
  v_ticket_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Login required';
  END IF;

  v_role := public.busnex_user_role();
  v_company_id := public.busnex_company_id();
  v_counter_id := public.busnex_counter_id();

  IF v_role IS NULL OR v_role NOT IN (
    'super_admin',
    'company_manager',
    'counter_operator'
  ) THEN
    RAISE EXCEPTION 'আপনার Reservation Confirm করার অনুমতি নেই';
  END IF;

  -- Lock the reservation first so two users cannot confirm/cancel it at once.
  SELECT r.* INTO v_res
  FROM public.ticket_reservations AS r
  JOIN public.trips AS t ON t.id = r.trip_id
  WHERE r.id = p_reservation_id
    AND (
      v_role = 'super_admin'
      OR (v_role = 'company_manager' AND t.company_id = v_company_id)
      OR (v_role = 'counter_operator'
          AND r.counter_id = v_counter_id
          AND t.company_id = v_company_id)
    )
  FOR UPDATE OF r;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reservation পাওয়া যায়নি অথবা আপনার অনুমতি নেই';
  END IF;

  IF v_res.status <> 'active' THEN
    RAISE EXCEPTION 'শুধু Active Reservation Confirm করে Ticket করা যাবে';
  END IF;

  IF v_res.expires_at IS NOT NULL AND v_res.expires_at <= now() THEN
    UPDATE public.ticket_reservations
    SET status = 'expired', updated_at = now()
    WHERE id = p_reservation_id;

    UPDATE public.trip_seats
    SET reservation_id = NULL
    WHERE reservation_id = p_reservation_id;

    -- Return normally so expiry cleanup commits instead of rolling back.
    RETURN false;
  END IF;

  SELECT t.* INTO v_trip
  FROM public.trips AS t
  WHERE t.id = v_res.trip_id
    AND t.is_active = true
    AND t.status = 'scheduled'
    AND (v_role = 'super_admin' OR t.company_id = v_company_id)
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Trip বন্ধ রয়েছে অথবা আপনার অনুমতি নেই';
  END IF;

  -- Preserve BUSNEX's existing Bangladesh-local past-date confirmation rule.
  IF (v_trip.departure_time AT TIME ZONE 'Asia/Dhaka')::date
       < (now() AT TIME ZONE 'Asia/Dhaka')::date
     AND NOT COALESCE(p_confirm_past_date, false) THEN
    RAISE EXCEPTION 'আগের তারিখের Trip। Ticket করার আগে নিশ্চিতকরণ প্রয়োজন';
  END IF;

  -- Validate the reservation's counter against the trip company and user role.
  SELECT c.company_id INTO v_counter_company_id
  FROM public.counters AS c
  WHERE c.id = v_res.counter_id
    AND c.is_active = true;

  IF v_counter_company_id IS NULL
     OR v_counter_company_id IS DISTINCT FROM v_trip.company_id THEN
    RAISE EXCEPTION 'Reservation-এর Counter সঠিক নয় অথবা বন্ধ রয়েছে';
  END IF;

  IF v_role = 'company_manager'
     AND v_counter_company_id IS DISTINCT FROM v_company_id THEN
    RAISE EXCEPTION 'অন্য Company-এর Counter ব্যবহার করা যাবে না';
  END IF;

  IF v_role = 'counter_operator' THEN
    IF v_counter_id IS NULL
       OR v_res.counter_id IS DISTINCT FROM v_counter_id
       OR v_company_id IS DISTINCT FROM v_trip.company_id
       OR NOT EXISTS (
         SELECT 1
         FROM public.counters AS c
         WHERE c.id = v_counter_id
           AND c.company_id = v_company_id
       ) THEN
      RAISE EXCEPTION 'এই Reservation আপনার নির্ধারিত Counter-এর নয়';
    END IF;
  END IF;

  SELECT count(*)::integer INTO v_seat_count
  FROM public.ticket_reservation_seats AS rs
  WHERE rs.reservation_id = p_reservation_id
    AND rs.trip_id = v_res.trip_id;

  IF v_seat_count < 1 OR v_seat_count > 8 THEN
    RAISE EXCEPTION 'Reservation-এ ১ থেকে ৮টি সঠিক Seat থাকতে হবে';
  END IF;

  -- Lock all inventory rows in stable order to prevent races with ticket sales.
  PERFORM ts.id
  FROM public.trip_seats AS ts
  JOIN public.ticket_reservation_seats AS rs
    ON rs.trip_id = ts.trip_id
   AND rs.seat_number = ts.seat_number
  WHERE rs.reservation_id = p_reservation_id
    AND ts.reservation_id = p_reservation_id
    AND ts.status = 'available'
  ORDER BY ts.seat_number
  FOR UPDATE OF ts;

  -- Every saved reservation seat must still belong to this reservation.
  IF EXISTS (
    SELECT 1
    FROM public.ticket_reservation_seats AS rs
    LEFT JOIN public.trip_seats AS ts
      ON ts.trip_id = rs.trip_id
     AND ts.seat_number = rs.seat_number
     AND ts.reservation_id = p_reservation_id
     AND ts.status = 'available'
    WHERE rs.reservation_id = p_reservation_id
      AND (rs.trip_id <> v_res.trip_id OR ts.id IS NULL)
  ) THEN
    RAISE EXCEPTION 'Reservation-এর এক বা একাধিক Seat আর এই Reservation-এর অধীনে নেই';
  END IF;

  -- Issue one real ticket per reserved seat. Existing cancelled ticket rows
  -- may be reused, matching the existing BUSNEX ticket-sale conflict behavior.
  FOR v_res_seat IN
    SELECT rs.*
    FROM public.ticket_reservation_seats AS rs
    WHERE rs.reservation_id = p_reservation_id
      AND rs.trip_id = v_res.trip_id
    ORDER BY rs.seat_number
  LOOP
    IF v_res_seat.passenger_name IS NULL
       OR btrim(v_res_seat.passenger_name) = ''
       OR v_res_seat.passenger_phone IS NULL
       OR btrim(v_res_seat.passenger_phone) = ''
       OR v_res_seat.passenger_gender IS NULL
       OR v_res_seat.passenger_gender NOT IN ('Male', 'Female') THEN
      RAISE EXCEPTION 'Seat %-এর Passenger তথ্য অসম্পূর্ণ', v_res_seat.seat_number;
    END IF;

    INSERT INTO public.tickets (
      trip_id,
      seat_number,
      passenger_name,
      passenger_phone,
      passenger_gender,
      counter_id,
      sold_by,
      boarding_stop_id,
      dropping_stop_id,
      ticket_price,
      status
    )
    VALUES (
      v_res.trip_id,
      btrim(v_res_seat.seat_number),
      btrim(v_res_seat.passenger_name),
      btrim(v_res_seat.passenger_phone),
      v_res_seat.passenger_gender,
      v_res.counter_id,
      auth.uid(),
      v_res_seat.boarding_stop_id,
      v_res_seat.dropping_stop_id,
      v_res_seat.ticket_price,
      'sold'
    )
    ON CONFLICT (trip_id, seat_number) WHERE (status = 'sold')
    DO NOTHING
    RETURNING id INTO v_ticket_id;

    IF v_ticket_id IS NULL THEN
      RAISE EXCEPTION 'Seat %-এর Ticket ইতিমধ্যে Sold রয়েছে', v_res_seat.seat_number;
    END IF;

    UPDATE public.trip_seats AS ts
    SET status = 'sold',
        reservation_id = NULL,
        hold_until = NULL,
        held_by = NULL,
        held_counter_id = NULL
    WHERE ts.trip_id = v_res.trip_id
      AND ts.seat_number = v_res_seat.seat_number
      AND ts.reservation_id = p_reservation_id
      AND ts.status = 'available';

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Seat %-কে Sold করা যায়নি', v_res_seat.seat_number;
    END IF;
  END LOOP;

  UPDATE public.ticket_reservations
  SET status = 'confirmed',
      confirmed_at = COALESCE(confirmed_at, now()),
      updated_at = now()
  WHERE id = p_reservation_id
    AND status = 'active';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reservation Status Confirm করা যায়নি';
  END IF;

  RETURN true;
END;
$function$;

-- Keep the original one-argument RPC callable by older clients.
-- It now performs the real ticket conversion, with past-date confirmation off.
CREATE OR REPLACE FUNCTION public.busnex_confirm_reservation(p_reservation_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  RETURN public.busnex_confirm_reservation(p_reservation_id, false);
END;
$function$;

REVOKE ALL ON FUNCTION public.busnex_confirm_reservation(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_confirm_reservation(uuid, boolean) TO authenticated;
REVOKE ALL ON FUNCTION public.busnex_confirm_reservation(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_confirm_reservation(uuid) TO authenticated;
