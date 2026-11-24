CREATE OR REPLACE FUNCTION public.busnex_confirm_reservation(p_reservation_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_res public.ticket_reservations%ROWTYPE;
  v_role text;
  v_company_id uuid;
  v_counter_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Login required';
  END IF;

  v_role := public.busnex_user_role();
  v_company_id := public.busnex_company_id();
  v_counter_id := public.busnex_counter_id();

  SELECT r.* INTO v_res
  FROM public.ticket_reservations AS r
  JOIN public.trips AS t ON t.id = r.trip_id
  WHERE r.id = p_reservation_id
    AND (
      v_role = 'super_admin'
      OR (v_role = 'company_manager' AND t.company_id = v_company_id)
      OR (v_role = 'counter_operator' AND r.counter_id = v_counter_id AND t.company_id = v_company_id)
    )
  FOR UPDATE OF r;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reservation পাওয়া যায়নি অথবা অনুমতি নেই';
  END IF;

  IF v_res.status <> 'active' THEN
    RAISE EXCEPTION 'শুধু Active Reservation Confirm করা যাবে';
  END IF;

  IF v_res.expires_at IS NOT NULL AND v_res.expires_at <= now() THEN
    UPDATE public.ticket_reservations
    SET status = 'expired',
        updated_at = now()
    WHERE id = p_reservation_id;

    UPDATE public.trip_seats
    SET reservation_id = NULL
    WHERE reservation_id = p_reservation_id;

    -- Return normally so the expiry and seat cleanup are committed.
    -- Raising an exception here would roll back both updates.
    RETURN false;
  END IF;

  UPDATE public.ticket_reservations
  SET confirmed_at = COALESCE(confirmed_at, now()),
      updated_at = now()
  WHERE id = p_reservation_id;

  RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION public.busnex_confirm_reservation(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_confirm_reservation(uuid) TO authenticated;
