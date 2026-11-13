-- BUSNEX late-departure and past-date ticket confirmation.
-- Same Bangladesh calendar date: sale/hold is allowed even after departure time.
-- Earlier Bangladesh calendar date: frontend must explicitly confirm; RPC validates the flag.
-- Regex-based transformation tolerates PostgreSQL's formatting of pg_get_functiondef.

DO $migration$
DECLARE
  v_definition text;
  v_updated text;
BEGIN
  SELECT pg_get_functiondef('public.busnex_hold_seat(uuid,text)'::regprocedure)
    INTO v_definition;

  v_updated := regexp_replace(
    v_definition,
    'CREATE OR REPLACE FUNCTION public[.]busnex_hold_seat[(]p_trip_id uuid,[[:space:]]*p_seat_number text[)]',
    'CREATE OR REPLACE FUNCTION public.busnex_hold_seat(p_trip_id uuid, p_seat_number text, p_confirm_past_date boolean)'
  );
  v_updated := regexp_replace(
    v_updated,
    'v_departure_time[[:space:]]+timestamptz;',
    'v_departure_time timestamptz;' || chr(10) ||
    '    v_confirm_past_date boolean := COALESCE(p_confirm_past_date, false);'
  );
  v_updated := regexp_replace(
    v_updated,
    'IF[[:space:]]+v_departure_time[[:space:]]*<=[[:space:]]*now[(][)][[:space:]]+THEN[[:space:]]*RAISE EXCEPTION [^;]*;[[:space:]]*END IF;',
    '-- Same-day late departures are allowed; compare Bangladesh local dates.' || chr(10) ||
    '    IF (v_departure_time AT TIME ZONE ''Asia/Dhaka'')::date' || chr(10) ||
    '       < (now() AT TIME ZONE ''Asia/Dhaka'')::date' || chr(10) ||
    '       AND NOT v_confirm_past_date THEN' || chr(10) ||
    '        RAISE EXCEPTION ''আগের তারিখের Trip। Ticket বিক্রির আগে নিশ্চিতকরণ প্রয়োজন'';' || chr(10) ||
    '    END IF;',
    'g'
  );

  IF v_updated = v_definition
     OR position('p_confirm_past_date boolean' IN v_updated) = 0
     OR position('Asia/Dhaka' IN v_updated) = 0
     OR position('IF v_departure_time <= now() THEN' IN v_updated) > 0 THEN
    RAISE EXCEPTION 'Could not safely transform busnex_hold_seat; no database changes applied';
  END IF;

  EXECUTE v_updated;

  SELECT pg_get_functiondef(
    'public.busnex_sell_ticket(uuid,text,text,text,uuid,uuid,text)'::regprocedure
  ) INTO v_definition;

  v_updated := regexp_replace(
    v_definition,
    'CREATE OR REPLACE FUNCTION public[.]busnex_sell_ticket[(]p_trip_id uuid,[[:space:]]*p_seat_number text,[[:space:]]*p_passenger_name text,[[:space:]]*p_passenger_phone text,[[:space:]]*p_boarding_stop_id uuid,[[:space:]]*p_dropping_stop_id uuid,[[:space:]]*p_passenger_gender text[)]',
    'CREATE OR REPLACE FUNCTION public.busnex_sell_ticket(p_trip_id uuid, p_seat_number text, p_passenger_name text, p_passenger_phone text, p_boarding_stop_id uuid, p_dropping_stop_id uuid, p_passenger_gender text, p_confirm_past_date boolean)'
  );
  v_updated := regexp_replace(
    v_updated,
    'v_departure_time[[:space:]]+timestamptz;',
    'v_departure_time timestamptz;' || chr(10) ||
    '    v_confirm_past_date boolean := COALESCE(p_confirm_past_date, false);'
  );
  v_updated := regexp_replace(
    v_updated,
    'IF[[:space:]]+v_departure_time[[:space:]]*<=[[:space:]]*now[(][)][[:space:]]+THEN[[:space:]]*RAISE EXCEPTION [^;]*;[[:space:]]*END IF;',
    '-- Same-day late departures are allowed; compare Bangladesh local dates.' || chr(10) ||
    '    IF (v_departure_time AT TIME ZONE ''Asia/Dhaka'')::date' || chr(10) ||
    '       < (now() AT TIME ZONE ''Asia/Dhaka'')::date' || chr(10) ||
    '       AND NOT v_confirm_past_date THEN' || chr(10) ||
    '        RAISE EXCEPTION ''আগের তারিখের Trip। Ticket বিক্রির আগে নিশ্চিতকরণ প্রয়োজন'';' || chr(10) ||
    '    END IF;',
    'g'
  );

  IF v_updated = v_definition
     OR position('p_confirm_past_date boolean' IN v_updated) = 0
     OR position('Asia/Dhaka' IN v_updated) = 0
     OR position('IF v_departure_time <= now() THEN' IN v_updated) > 0 THEN
    RAISE EXCEPTION 'Could not safely transform busnex_sell_ticket; no database changes applied';
  END IF;

  EXECUTE v_updated;
END;
$migration$;

-- Remove execute access to legacy signatures so confirmation cannot be bypassed.
REVOKE ALL ON FUNCTION public.busnex_hold_seat(uuid,text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.busnex_sell_ticket(uuid,text,text,text,uuid,uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.busnex_sell_ticket(uuid,text,text,text,uuid,uuid,text)
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.busnex_hold_seat(uuid,text,boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_hold_seat(uuid,text,boolean)
  TO authenticated;

REVOKE ALL ON FUNCTION public.busnex_sell_ticket(uuid,text,text,text,uuid,uuid,text,boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_sell_ticket(uuid,text,text,text,uuid,uuid,text,boolean)
  TO authenticated;
