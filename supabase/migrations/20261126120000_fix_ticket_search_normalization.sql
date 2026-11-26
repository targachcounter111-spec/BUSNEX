-- Make global PNR/mobile search tolerant of printed PNR formatting and BD phone formats.
-- Keep the existing role + company/region authorization boundary.
CREATE OR REPLACE FUNCTION public.busnex_ticket_search(p_query text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_role text;
  v_q text;
  v_pnr_query text;
  v_phone_query text;
  v_rows jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'অনুমতি নেই';
  END IF;

  v_role := public.busnex_user_role();
  IF v_role NOT IN (
    'super_admin',
    'company_manager',
    'counter_operator',
    'nb_sub_manager',
    'dhaka_sub_manager'
  ) THEN
    RAISE EXCEPTION 'অনুমতি নেই';
  END IF;

  v_q := trim(coalesce(p_query, ''));
  v_pnr_query := upper(
    regexp_replace(
      regexp_replace(v_q, '^[[:space:]]*PNR[[:space:]:#-]*', '', 'i'),
      '[^A-Za-z0-9]', '', 'g'
    )
  );
  v_phone_query := regexp_replace(v_q, '[^0-9]', '', 'g');

  -- Treat Bangladesh international and local mobile notation as equivalent.
  IF left(v_phone_query, 3) = '880' AND length(v_phone_query) = 13 THEN
    v_phone_query := '0' || substr(v_phone_query, 4);
  END IF;

  IF length(v_pnr_query) < 4 AND length(v_phone_query) < 4 THEN
    RETURN jsonb_build_object('tickets', '[]'::jsonb);
  END IF;

  SELECT coalesce(jsonb_agg(ticket), '[]'::jsonb)
    INTO v_rows
  FROM (
    SELECT jsonb_build_object(
      'ticket_id', t.id,
      'pnr', upper(left(t.id::text, 13)),
      'seat_number', t.seat_number,
      'passenger_name', t.passenger_name,
      'passenger_phone', t.passenger_phone,
      'ticket_price', t.ticket_price,
      'discount_amount', t.discount_amount,
      'paid_price', t.paid_price,
      'created_at', t.created_at,
      'trip_id', tr.id,
      'coach_number', tr.coach_number,
      'bus_name', tr.bus_name,
      'departure_time', tr.departure_time,
      'starting_point', tr.starting_point,
      'ending_point', tr.ending_point,
      'status', t.status
    ) AS ticket
    FROM public.tickets t
    JOIN public.trips tr ON tr.id = t.trip_id
    CROSS JOIN LATERAL (
      SELECT regexp_replace(coalesce(t.passenger_phone, ''), '[^0-9]', '', 'g') AS phone_digits
    ) phone
    WHERE t.status = 'sold'
      AND public.busnex_can_access_trip_region(tr.id)
      AND (
        (
          length(v_pnr_query) >= 4
          AND replace(t.id::text, '-', '') ILIKE v_pnr_query || '%'
        )
        OR
        (
          length(v_phone_query) >= 4
          AND (
            CASE
              WHEN left(phone.phone_digits, 3) = '880' AND length(phone.phone_digits) = 13
                THEN '0' || substr(phone.phone_digits, 4)
              ELSE phone.phone_digits
            END
          ) LIKE '%' || v_phone_query || '%'
        )
      )
    ORDER BY t.created_at DESC
    LIMIT 30
  ) matches;

  RETURN jsonb_build_object('tickets', v_rows);
END;
$function$;

REVOKE ALL ON FUNCTION public.busnex_ticket_search(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_ticket_search(text) TO authenticated;
