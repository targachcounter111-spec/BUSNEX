-- BUSNEX: atomic multi-seat ticket sale (maximum 8 seats).
-- A failure on any seat aborts the entire RPC transaction; no partial group sale.
CREATE OR REPLACE FUNCTION public.busnex_sell_tickets_batch(
  p_trip_id uuid,
  p_seat_numbers text[],
  p_passenger_name text,
  p_passenger_phone text,
  p_boarding_stop_id uuid,
  p_dropping_stop_id uuid,
  p_passenger_gender text,
  p_confirm_past_date boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO ''
AS $function$
DECLARE
  v_seat text;
  v_result jsonb := '[]'::jsonb;
  v_ticket jsonb;
  v_count integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Login required';
  END IF;

  IF p_seat_numbers IS NULL THEN
    RAISE EXCEPTION 'কমপক্ষে একটি Seat নির্বাচন করুন';
  END IF;

  v_count := cardinality(p_seat_numbers);
  IF v_count < 1 OR v_count > 8 THEN
    RAISE EXCEPTION 'একসঙ্গে সর্বোচ্চ ৮টি Seat বিক্রি করা যাবে';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM unnest(p_seat_numbers) AS requested(seat_number)
    WHERE requested.seat_number IS NULL
       OR btrim(requested.seat_number) = ''
  ) THEN
    RAISE EXCEPTION 'Invalid seat number';
  END IF;

  IF (SELECT count(DISTINCT btrim(requested.seat_number)) FROM unnest(p_seat_numbers) AS requested(seat_number)) <> v_count THEN
    RAISE EXCEPTION 'একই Seat একাধিকবার নির্বাচন করা হয়েছে';
  END IF;

  FOR v_seat IN
    SELECT btrim(requested.seat_number)
    FROM unnest(p_seat_numbers) AS requested(seat_number)
    ORDER BY btrim(requested.seat_number)
  LOOP
    v_ticket := pg_catalog.to_jsonb(public.busnex_sell_ticket(
      p_trip_id,
      v_seat,
      p_passenger_name,
      p_passenger_phone,
      p_boarding_stop_id,
      p_dropping_stop_id,
      p_passenger_gender,
      COALESCE(p_confirm_past_date, false)
    ));

    v_result := v_result || jsonb_build_array(
      jsonb_build_object('seat_number', v_seat, 'result', v_ticket)
    );
  END LOOP;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.busnex_sell_tickets_batch(uuid, text[], text, text, uuid, uuid, text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.busnex_sell_tickets_batch(uuid, text[], text, text, uuid, uuid, text, boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.busnex_sell_tickets_batch(uuid, text[], text, text, uuid, uuid, text, boolean) TO authenticated;
