-- BUSNEX: release trip seat inventory when expired reservations are lazily expired during creation.
-- This preserves the existing reservation rules and clears stale reservation_id references.
CREATE OR REPLACE FUNCTION public.busnex_create_reservation(
  p_trip_id uuid,
  p_reservation_type text,
  p_seat_numbers text[],
  p_passenger_name text,
  p_passenger_phone text,
  p_passenger_gender text,
  p_boarding_stop_id uuid,
  p_dropping_stop_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_role text;
  v_company_id uuid;
  v_counter_id uuid;
  v_trip public.trips%ROWTYPE;
  v_reservation_id uuid;
  v_expiry timestamptz;
  v_seat text;
  v_seat_row public.trip_seats%ROWTYPE;
  v_seat_count integer;
  v_board_order integer;
  v_drop_order integer;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Login required'; END IF;
  v_role := public.busnex_user_role();
  v_company_id := public.busnex_company_id();
  v_counter_id := public.busnex_counter_id();

  IF v_role IS DISTINCT FROM 'counter_operator' OR v_counter_id IS NULL THEN
    RAISE EXCEPTION 'শুধু নির্ধারিত Counter Operator Reservation তৈরি করতে পারবেন';
  END IF;
  IF p_reservation_type IS NULL OR p_reservation_type NOT IN ('standard','vip') THEN
    RAISE EXCEPTION 'Invalid reservation type';
  END IF;
  IF p_passenger_name IS NULL OR btrim(p_passenger_name) = ''
     OR p_passenger_phone IS NULL OR btrim(p_passenger_phone) = ''
     OR p_passenger_gender IS NULL OR p_passenger_gender NOT IN ('Male','Female') THEN
    RAISE EXCEPTION 'Passenger name, phone and gender are required';
  END IF;
  IF p_seat_numbers IS NULL OR cardinality(p_seat_numbers) < 1 OR cardinality(p_seat_numbers) > 8 THEN
    RAISE EXCEPTION 'একসঙ্গে ১ থেকে ৮টি Seat Reservation করা যাবে';
  END IF;
  IF EXISTS (
    SELECT 1 FROM unnest(p_seat_numbers) AS s(seat)
    WHERE s.seat IS NULL OR btrim(s.seat) = ''
  ) OR (SELECT count(DISTINCT btrim(s.seat)) FROM unnest(p_seat_numbers) AS s(seat)) <> cardinality(p_seat_numbers) THEN
    RAISE EXCEPTION 'Seat list invalid or contains duplicates';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.counter_reservation_permissions p
    WHERE p.counter_id = v_counter_id
      AND p.company_id = v_company_id
      AND p.reservation_type = p_reservation_type
      AND p.is_active = true
  ) THEN
    RAISE EXCEPTION 'এই Counter-এর জন্য এই ধরনের Reservation Permission নেই';
  END IF;

  SELECT * INTO v_trip
  FROM public.trips t
  WHERE t.id = p_trip_id
    AND t.company_id = v_company_id
    AND t.is_active = true
    AND t.status = 'scheduled'
  FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Trip পাওয়া যায়নি অথবা বন্ধ রয়েছে'; END IF;
  IF v_trip.departure_time <= now() THEN RAISE EXCEPTION 'Departure Time পার হয়ে গেছে'; END IF;

  IF p_reservation_type = 'standard' THEN
    v_expiry := v_trip.departure_time - interval '5 minutes';
    IF v_expiry <= now() THEN RAISE EXCEPTION 'Standard Reservation-এর সময় শেষ'; END IF;
  ELSE
    v_expiry := NULL;
  END IF;

  SELECT ts.stop_order INTO v_board_order
  FROM public.trip_stops ts
  WHERE ts.id = p_boarding_stop_id AND ts.trip_id = p_trip_id AND ts.is_active = true;
  SELECT ts.stop_order INTO v_drop_order
  FROM public.trip_stops ts
  WHERE ts.id = p_dropping_stop_id AND ts.trip_id = p_trip_id AND ts.is_active = true;
  IF v_board_order IS NULL OR v_drop_order IS NULL OR v_board_order >= v_drop_order THEN
    RAISE EXCEPTION 'Boarding ও Dropping Stop সঠিকভাবে নির্বাচন করুন';
  END IF;

  -- Lock all requested inventory rows in stable order to prevent racing reservations.
  FOR v_seat IN
    SELECT btrim(s.seat) FROM unnest(p_seat_numbers) AS s(seat) ORDER BY btrim(s.seat)
  LOOP
    SELECT ts.* INTO v_seat_row
    FROM public.trip_seats ts
    WHERE ts.trip_id = p_trip_id AND ts.seat_number = v_seat
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Seat % পাওয়া যায়নি', v_seat; END IF;
    IF v_seat_row.status NOT IN ('available','held') THEN
      RAISE EXCEPTION 'Seat % এখন Reservation-এর জন্য Available নয়', v_seat;
    END IF;
    IF v_seat_row.status = 'held'
       AND v_seat_row.hold_until > now()
       AND v_seat_row.held_by IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION 'Seat % অন্য Counter/User-এর Temporary Hold-এ আছে', v_seat;
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.tickets tk
      WHERE tk.trip_id = p_trip_id AND tk.seat_number = v_seat AND tk.status = 'sold'
    ) OR EXISTS (
      SELECT 1 FROM public.ticket_reservation_seats rs
      JOIN public.ticket_reservations r ON r.id = rs.reservation_id
      WHERE rs.trip_id = p_trip_id AND rs.seat_number = v_seat
        AND r.status IN ('active','confirmed')
        AND (r.expires_at IS NULL OR r.expires_at > now())
    ) THEN
      RAISE EXCEPTION 'Seat % ইতিমধ্যে বিক্রি বা Reserved', v_seat;
    END IF;
  END LOOP;

  -- Expire old reservations and release every linked inventory row atomically.
  WITH expired_reservations AS (
    UPDATE public.ticket_reservations AS r
    SET status = 'expired',
        updated_at = now()
    WHERE r.trip_id = p_trip_id
      AND r.status = 'active'
      AND r.expires_at IS NOT NULL
      AND r.expires_at <= now()
    RETURNING r.id
  )
  UPDATE public.trip_seats AS ts
  SET reservation_id = NULL
  WHERE ts.reservation_id IN (
    SELECT er.id
    FROM expired_reservations AS er
  );

  INSERT INTO public.ticket_reservations
    (trip_id, counter_id, reserved_by, reservation_type, status, expires_at, created_at, updated_at)
  VALUES
    (p_trip_id, v_counter_id, auth.uid(), p_reservation_type, 'active', v_expiry, now(), now())
  RETURNING id INTO v_reservation_id;

  INSERT INTO public.ticket_reservation_seats
    (reservation_id, trip_id, seat_number, passenger_name, passenger_phone,
     passenger_gender, boarding_stop_id, dropping_stop_id, ticket_price, created_at)
  SELECT v_reservation_id, p_trip_id, btrim(s.seat), btrim(p_passenger_name),
         btrim(p_passenger_phone), p_passenger_gender, p_boarding_stop_id,
         p_dropping_stop_id, v_trip.ticket_price, now()
  FROM unnest(p_seat_numbers) AS s(seat);

  UPDATE public.trip_seats
  SET reservation_id=v_reservation_id,
      status='available',
      hold_until=NULL,
      held_by=NULL,
      held_counter_id=NULL
  WHERE trip_id=p_trip_id AND seat_number IN (
    SELECT btrim(s.seat) FROM unnest(p_seat_numbers) AS s(seat)
  );

  RETURN v_reservation_id;
END;
$function$;
