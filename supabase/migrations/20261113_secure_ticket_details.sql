-- BUSNEX: secure ticket detail lookup for authorized users.
-- Apply this migration in Supabase SQL Editor before relying on the new popup.
CREATE OR REPLACE FUNCTION public.busnex_get_ticket_details(
  p_trip_id uuid,
  p_seat_number text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_role text;
  v_company_id uuid;
  v_counter_id uuid;
  v_result jsonb;
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
    RAISE EXCEPTION 'Permission denied';
  END IF;

  SELECT jsonb_build_object(
    'ticket', jsonb_build_object(
      'id', tk.id,
      'seat_number', tk.seat_number,
      'passenger_name', tk.passenger_name,
      'passenger_phone', tk.passenger_phone,
      'passenger_gender', tk.passenger_gender,
      'ticket_price', tk.ticket_price,
      'status', tk.status,
      'created_at', tk.created_at,
      'sold_by', tk.sold_by,
      'counter_id', tk.counter_id,
      'boarding_stop_id', tk.boarding_stop_id,
      'dropping_stop_id', tk.dropping_stop_id
    ),
    'trip', jsonb_build_object(
      'departure_time', tr.departure_time,
      'coach_number', tr.coach_number,
      'bus_name', b.bus_name,
      'starting_point', r.starting_point,
      'ending_point', r.ending_point
    ),
    'boarding_stop_name', bs.stop_name,
    'dropping_stop_name', ds.stop_name,
    'seller', jsonb_build_object(
      'seller_name', COALESCE(p.full_name, 'নাম পাওয়া যায়নি'),
      'seller_role', COALESCE(p.role, 'তথ্য নেই'),
      'counter_name', COALESCE(c.name, 'Counter নেই')
    )
  )
  INTO v_result
  FROM public.tickets tk
  JOIN public.trips tr ON tr.id = tk.trip_id
  LEFT JOIN public.buses b ON b.id = tr.bus_id
  LEFT JOIN public.routes r ON r.id = tr.route_id
  LEFT JOIN public.trip_stops bs ON bs.id = tk.boarding_stop_id
  LEFT JOIN public.trip_stops ds ON ds.id = tk.dropping_stop_id
  LEFT JOIN public.profiles p ON p.id = tk.sold_by
  LEFT JOIN public.counters c ON c.id = COALESCE(tk.counter_id, p.counter_id)
  WHERE tk.trip_id = p_trip_id
    AND tk.seat_number = btrim(p_seat_number)
    AND tk.status = 'sold'
    AND (
      v_role = 'super_admin'
      OR (
        v_role = 'company_manager'
        AND v_company_id IS NOT NULL
        AND tr.company_id = v_company_id
      )
      OR (
        v_role = 'counter_operator'
        AND v_company_id IS NOT NULL
        AND v_counter_id IS NOT NULL
        AND tr.company_id = v_company_id
        AND tk.counter_id = v_counter_id
      )
    );

  IF v_result IS NULL THEN
    RAISE EXCEPTION 'Ticket not found or access denied';
  END IF;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.busnex_get_ticket_details(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.busnex_get_ticket_details(uuid, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.busnex_get_ticket_details(uuid, text) TO authenticated;
