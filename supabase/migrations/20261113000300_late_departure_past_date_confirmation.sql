-- BUSNEX late-departure and past-date ticket confirmation.
-- Same Bangladesh calendar date: sale/hold is allowed even after departure time.
-- Earlier Bangladesh calendar date: frontend must explicitly confirm; RPC validates the flag.
-- Disable legacy overloads so authenticated clients cannot bypass the required flag.

DO $migration$
DECLARE
  v_definition text;
  v_updated text;
BEGIN
  SELECT pg_get_functiondef('public.busnex_hold_seat(uuid,text)'::regprocedure)
    INTO v_definition;

  v_updated := replace(
    v_definition,
    'public.busnex_hold_seat(p_trip_id uuid, p_seat_number text)',
    'public.busnex_hold_seat(p_trip_id uuid, p_seat_number text, p_confirm_past_date boolean)'
  );
  v_updated := replace(
    v_updated,
    '    v_departure_time timestamptz;',
    '    v_departure_time timestamptz;' || chr(10) ||
    '    v_confirm_past_date boolean := COALESCE(p_confirm_past_date, false);'
  );
  v_updated := replace(
    v_updated,
    '    IF v_departure_time <= now() THEN' || chr(10) ||
    '        RAISE EXCEPTION ''Trip-এর Departure Time পার হয়ে গেছে'';' || chr(10) ||
    '    END IF;',
    '    -- Same-day late departures are allowed; compare Bangladesh local dates.' || chr(10) ||
    '    IF (v_departure_time AT TIME ZONE ''Asia/Dhaka'')::date' || chr(10) ||
    '       < (now() AT TIME ZONE ''Asia/Dhaka'')::date' || chr(10) ||
    '       AND NOT v_confirm_past_date THEN' || chr(10) ||
    '        RAISE EXCEPTION ''আগের তারিখের Trip। Ticket বিক্রির আগে নিশ্চিতকরণ প্রয়োজন'';' || chr(10) ||
    '    END IF;'
  );

  IF v_updated = v_definition
     OR position('p_confirm_past_date boolean' IN v_updated) = 0
     OR position('Asia/Dhaka' IN v_updated) = 0 THEN
    RAISE EXCEPTION 'Could not safely transform busnex_hold_seat; no database changes applied';
  END IF;

  EXECUTE v_updated;

  SELECT pg_get_functiondef(
    'public.busnex_sell_ticket(uuid,text,text,text,uuid,uuid,text)'::regprocedure
  ) INTO v_definition;

  v_updated := replace(
    v_definition,
    'public.busnex_sell_ticket(p_trip_id uuid, p_seat_number text, p_passenger_name text, p_passenger_phone text, p_boarding_stop_id uuid, p_dropping_stop_id uuid, p_passenger_gender text)',
    'public.busnex_sell_ticket(p_trip_id uuid, p_seat_number text, p_passenger_name text, p_passenger_phone text, p_boarding_stop_id uuid, p_dropping_stop_id uuid, p_passenger_gender text, p_confirm_past_date boolean)'
  );
  v_updated := replace(
    v_updated,
    '    v_departure_time timestamptz;',
    '    v_departure_time timestamptz;' || chr(10) ||
    '    v_confirm_past_date boolean := COALESCE(p_confirm_past_date, false);'
  );
  v_updated := replace(
    v_updated,
    '    IF v_departure_time <= now() THEN' || chr(10) ||
    '        RAISE EXCEPTION ''Trip-এর Departure Time পার হয়ে গেছে'';' || chr(10) ||
    '    END IF;',
    '    -- Same-day late departures are allowed; compare Bangladesh local dates.' || chr(10) ||
    '    IF (v_departure_time AT TIME ZONE ''Asia/Dhaka'')::date' || chr(10) ||
    '       < (now() AT TIME ZONE ''Asia/Dhaka'')::date' || chr(10) ||
    '       AND NOT v_confirm_past_date THEN' || chr(10) ||
    '        RAISE EXCEPTION ''আগের তারিখের Trip। Ticket বিক্রির আগে নিশ্চিতকরণ প্রয়োজন'';' || chr(10) ||
    '    END IF;'
  );

  IF v_updated = v_definition
     OR position('p_confirm_past_date boolean' IN v_updated) = 0
     OR position('Asia/Dhaka' IN v_updated) = 0 THEN
    RAISE EXCEPTION 'Could not safely transform busnex_sell_ticket; no database changes applied';
  END IF;

  EXECUTE v_updated;
END;
$migration$;

-- Remove execute access to all old signatures.
REVOKE ALL ON FUNCTION public.busnex_hold_seat(uuid,text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.busnex_sell_ticket(uuid,text,text,text,uuid,uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.busnex_sell_ticket(uuid,text,text,text,uuid,uuid,text)
  FROM PUBLIC, anon, authenticated;

-- Only the new explicit-confirmation signatures are callable by logged-in users.
REVOKE ALL ON FUNCTION public.busnex_hold_seat(uuid,text,boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_hold_seat(uuid,text,boolean)
  TO authenticated;

REVOKE ALL ON FUNCTION public.busnex_sell_ticket(uuid,text,text,text,uuid,uuid,text,boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_sell_ticket(uuid,text,text,text,uuid,uuid,text,boolean)
  TO authenticated;
