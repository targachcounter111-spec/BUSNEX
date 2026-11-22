-- BUSNEX: keep Sub Manager role permissions separate from assigned region.
-- The role (NB/Dhaka Sub Manager) controls capability; profiles.region controls data scope.

ALTER TABLE public.profiles
  DROP CONSTRAINT IF EXISTS profiles_sub_manager_region_check;

CREATE OR REPLACE FUNCTION public.busnex_is_region_sub_manager(p_region text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.profiles p
    WHERE p.id = auth.uid()
      AND p.is_active IS DISTINCT FROM false
      AND p.role IN ('nb_sub_manager', 'dhaka_sub_manager')
      AND p.region = p_region
      AND p.region IN ('NB', 'DHAKA', 'SB')
  )
$$;

REVOKE ALL ON FUNCTION public.busnex_is_region_sub_manager(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_is_region_sub_manager(text) TO authenticated;

-- Sub Managers can see/create counters only in their assigned region.
DROP POLICY IF EXISTS counters_sub_manager_select ON public.counters;
CREATE POLICY counters_sub_manager_select ON public.counters
FOR SELECT TO authenticated
USING (
  company_id = public.busnex_company_id()
  AND public.busnex_is_region_sub_manager(region)
);

DROP POLICY IF EXISTS counters_nb_sub_manager_insert ON public.counters;
DROP POLICY IF EXISTS counters_dhaka_sub_manager_insert ON public.counters;
DROP POLICY IF EXISTS counters_sub_manager_insert ON public.counters;
CREATE POLICY counters_sub_manager_insert ON public.counters
FOR INSERT TO authenticated
WITH CHECK (
  company_id = public.busnex_company_id()
  AND public.busnex_is_region_sub_manager(region)
);

-- Reservation lists follow assigned region, while the role's existing actions remain unchanged.
DROP POLICY IF EXISTS ticket_reservations_nb_sub_manager_select ON public.ticket_reservations;
DROP POLICY IF EXISTS ticket_reservations_sub_manager_select ON public.ticket_reservations;
CREATE POLICY ticket_reservations_sub_manager_select ON public.ticket_reservations
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.trips t
    JOIN public.routes r ON r.id = t.route_id
    WHERE t.id = ticket_reservations.trip_id
      AND t.company_id = public.busnex_company_id()
      AND r.company_id = t.company_id
      AND public.busnex_is_region_sub_manager(r.region)
  )
);

DROP POLICY IF EXISTS ticket_reservation_seats_nb_sub_manager_select ON public.ticket_reservation_seats;
DROP POLICY IF EXISTS ticket_reservation_seats_sub_manager_select ON public.ticket_reservation_seats;
CREATE POLICY ticket_reservation_seats_sub_manager_select ON public.ticket_reservation_seats
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.ticket_reservations tr
    JOIN public.trips t ON t.id = tr.trip_id
    JOIN public.routes r ON r.id = t.route_id
    WHERE tr.id = ticket_reservation_seats.reservation_id
      AND t.company_id = public.busnex_company_id()
      AND r.company_id = t.company_id
      AND public.busnex_is_region_sub_manager(r.region)
  )
);

-- Reservation booking counters are limited to the logged-in Sub Manager's assigned region.
CREATE OR REPLACE FUNCTION public.busnex_get_reservation_booking_counters(p_company_id uuid)
RETURNS TABLE(counter_id uuid, counter_name text, counter_address text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_role text;
  v_company_id uuid;
  v_region text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Login required';
  END IF;

  v_role := public.busnex_user_role();
  v_company_id := public.busnex_company_id();
  v_region := public.busnex_user_region();

  IF v_role = 'company_manager' THEN
    IF v_company_id IS NULL OR (p_company_id IS NOT NULL AND p_company_id <> v_company_id) THEN
      RAISE EXCEPTION 'অন্য Company-এর Counter দেখা যাবে না';
    END IF;
  ELSIF v_role = 'super_admin' THEN
    IF p_company_id IS NULL THEN
      RAISE EXCEPTION 'Company নির্বাচন করুন';
    END IF;
    v_company_id := p_company_id;
  ELSIF v_role IN ('nb_sub_manager', 'dhaka_sub_manager') THEN
    IF v_company_id IS NULL
       OR (p_company_id IS NOT NULL AND p_company_id <> v_company_id)
       OR v_region NOT IN ('NB', 'DHAKA', 'SB') THEN
      RAISE EXCEPTION 'অন্য Company বা Region-এর Counter দেখা যাবে না';
    END IF;
  ELSE
    RAISE EXCEPTION 'Not authorized';
  END IF;

  RETURN QUERY
    SELECT c.id, c.name, c.address
    FROM public.counters c
    WHERE c.company_id = v_company_id
      AND c.is_active = true
      AND (
        v_role IN ('company_manager', 'super_admin')
        OR (v_role IN ('nb_sub_manager', 'dhaka_sub_manager') AND c.region = v_region)
      )
    ORDER BY c.name;
END;
$function$;

REVOKE ALL ON FUNCTION public.busnex_get_reservation_booking_counters(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_get_reservation_booking_counters(uuid) TO authenticated;

-- Preserve NB Sub Manager-only seat-block permission, but scope it to the selected region.
CREATE OR REPLACE FUNCTION public.busnex_nb_set_trip_seat_block(
  p_trip_id uuid,
  p_seat_number text,
  p_blocked boolean
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE
  v_status text;
  v_region text;
BEGIN
  v_region := public.busnex_user_region();
  IF auth.uid() IS NULL
     OR public.busnex_user_role() <> 'nb_sub_manager'
     OR v_region NOT IN ('NB', 'DHAKA', 'SB') THEN
    RAISE EXCEPTION 'শুধু NB Sub Manager এই কাজ করতে পারবেন';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.trips t
    JOIN public.routes r ON r.id=t.route_id
    WHERE t.id=p_trip_id
      AND t.company_id=public.busnex_company_id()
      AND r.company_id=t.company_id
      AND public.busnex_is_region_sub_manager(r.region)
  ) THEN
    RAISE EXCEPTION 'এই Assigned Region-এর Trip-এর অনুমতি পাওয়া যায়নি';
  END IF;

  SELECT status INTO v_status
  FROM public.trip_seats
  WHERE trip_id=p_trip_id AND seat_number=btrim(p_seat_number)
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Seat পাওয়া যায়নি'; END IF;

  IF p_blocked THEN
    IF v_status <> 'available' THEN
      RAISE EXCEPTION 'শুধু Available Seat Block করা যাবে; Sold, Reserved বা Held Seat নয়';
    END IF;
    UPDATE public.trip_seats
    SET status='blocked', hold_until=NULL, held_by=NULL, held_counter_id=NULL
    WHERE trip_id=p_trip_id AND seat_number=btrim(p_seat_number) AND status='available';
  ELSE
    IF v_status <> 'blocked' THEN
      RAISE EXCEPTION 'শুধু Blocked Seat খুলতে পারবেন';
    END IF;
    UPDATE public.trip_seats
    SET status='available'
    WHERE trip_id=p_trip_id AND seat_number=btrim(p_seat_number) AND status='blocked';
  END IF;
  RETURN FOUND;
END;
$$;

REVOKE ALL ON FUNCTION public.busnex_nb_set_trip_seat_block(uuid,text,boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_nb_set_trip_seat_block(uuid,text,boolean) TO authenticated;

-- Preserve NB Sub Manager-only reservation cancellation, scoped to assigned region.
CREATE OR REPLACE FUNCTION public.busnex_nb_cancel_reservation(p_reservation_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE
  v_status text;
BEGIN
  IF auth.uid() IS NULL
     OR public.busnex_user_role() <> 'nb_sub_manager'
     OR public.busnex_user_region() NOT IN ('NB', 'DHAKA', 'SB') THEN
    RAISE EXCEPTION 'শুধু NB Sub Manager Reservation Cancel করতে পারবেন';
  END IF;

  SELECT tr.status INTO v_status
  FROM public.ticket_reservations tr
  JOIN public.trips t ON t.id=tr.trip_id
  JOIN public.routes r ON r.id=t.route_id
  WHERE tr.id=p_reservation_id
    AND t.company_id=public.busnex_company_id()
    AND r.company_id=t.company_id
    AND public.busnex_is_region_sub_manager(r.region)
  FOR UPDATE OF tr;

  IF NOT FOUND THEN RAISE EXCEPTION 'Assigned Region-এর Reservation পাওয়া যায়নি অথবা অনুমতি নেই'; END IF;
  IF v_status <> 'active' THEN RAISE EXCEPTION 'শুধু Active Reservation Cancel করা যাবে'; END IF;

  UPDATE public.ticket_reservations
  SET status='cancelled', updated_at=now()
  WHERE id=p_reservation_id AND status='active';

  UPDATE public.trip_seats
  SET reservation_id=NULL
  WHERE reservation_id=p_reservation_id;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.busnex_nb_cancel_reservation(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_nb_cancel_reservation(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
