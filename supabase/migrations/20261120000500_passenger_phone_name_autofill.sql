-- BUSNEX: privacy-scoped passenger name autofill by phone.
-- Returns only the most recent sold-ticket passenger name, never phone/history data.

CREATE OR REPLACE FUNCTION public.busnex_find_passenger_name_by_phone(
  p_trip_id uuid,
  p_phone text
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_role text;
  v_company_id uuid;
  v_counter_id uuid;
  v_trip_company_id uuid;
  v_phone_digits text;
  v_phone_key text;
  v_name text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Login required';
  END IF;

  v_role := public.busnex_user_role();
  v_company_id := public.busnex_company_id();
  v_counter_id := public.busnex_counter_id();

  IF v_role NOT IN ('super_admin', 'company_manager', 'counter_operator') THEN
    RAISE EXCEPTION 'Permission denied';
  END IF;

  v_phone_digits := regexp_replace(COALESCE(p_phone, ''), '[^0-9]', '', 'g');
  IF length(v_phone_digits) < 8 OR length(v_phone_digits) > 15 THEN
    RETURN NULL;
  END IF;
  v_phone_key := CASE
    WHEN left(v_phone_digits, 3) = '880' THEN '0' || substr(v_phone_digits, 4)
    ELSE v_phone_digits
  END;

  SELECT tr.company_id
    INTO v_trip_company_id
  FROM public.trips tr
  WHERE tr.id = p_trip_id;

  IF v_trip_company_id IS NULL THEN
    RAISE EXCEPTION 'Trip not found or access denied';
  END IF;

  IF v_role = 'company_manager'
     AND (v_company_id IS NULL OR v_trip_company_id <> v_company_id) THEN
    RAISE EXCEPTION 'Permission denied';
  ELSIF v_role = 'counter_operator'
     AND (v_company_id IS NULL OR v_counter_id IS NULL
          OR v_trip_company_id <> v_company_id) THEN
    RAISE EXCEPTION 'Permission denied';
  END IF;

  SELECT NULLIF(btrim(tk.passenger_name), '')
    INTO v_name
  FROM public.tickets tk
  JOIN public.trips old_trip ON old_trip.id = tk.trip_id
  WHERE old_trip.company_id = v_trip_company_id
    AND tk.status = 'sold'
    AND (
      v_role <> 'counter_operator'
      OR tk.counter_id = v_counter_id
    )
    AND (
      CASE
        WHEN left(regexp_replace(COALESCE(tk.passenger_phone, ''), '[^0-9]', '', 'g'), 3) = '880'
          THEN '0' || substr(regexp_replace(COALESCE(tk.passenger_phone, ''), '[^0-9]', '', 'g'), 4)
        ELSE regexp_replace(COALESCE(tk.passenger_phone, ''), '[^0-9]', '', 'g')
      END
    ) = v_phone_key
    AND NULLIF(btrim(tk.passenger_name), '') IS NOT NULL
  ORDER BY tk.created_at DESC
  LIMIT 1;

  RETURN v_name;
END;
$function$;

REVOKE ALL ON FUNCTION public.busnex_find_passenger_name_by_phone(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_find_passenger_name_by_phone(uuid, text) TO authenticated;
