-- BUSNEX: NB Sub Manager counter creation, trip seat blocking and reservation cancellation.
-- All write operations are server-verified against the user's company and NB route region.

ALTER TABLE public.counters
  ADD COLUMN IF NOT EXISTS region text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.counters'::regclass
      AND conname='counters_region_check'
  ) THEN
    ALTER TABLE public.counters
      ADD CONSTRAINT counters_region_check
      CHECK (region IS NULL OR region IN ('NB','SB','DHAKA','ALL'));
  END IF;
END $$;

DROP POLICY IF EXISTS counters_sub_manager_select ON public.counters;
CREATE POLICY counters_sub_manager_select ON public.counters
FOR SELECT TO authenticated
USING (
  company_id = public.busnex_company_id()
  AND (
    (public.busnex_user_role()='nb_sub_manager' AND region='NB')
    OR (public.busnex_user_role()='dhaka_sub_manager' AND region='DHAKA')
  )
);

DROP POLICY IF EXISTS counters_nb_sub_manager_insert ON public.counters;
CREATE POLICY counters_nb_sub_manager_insert ON public.counters
FOR INSERT TO authenticated
WITH CHECK (
  company_id = public.busnex_company_id()
  AND region='NB'
  AND public.busnex_user_role()='nb_sub_manager'
  AND public.busnex_user_region()='NB'
);

-- Reservation visibility for NB Sub Managers is restricted to NB trips in their company.
DROP POLICY IF EXISTS ticket_reservations_nb_sub_manager_select ON public.ticket_reservations;
CREATE POLICY ticket_reservations_nb_sub_manager_select ON public.ticket_reservations
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.trips t
    JOIN public.routes r ON r.id=t.route_id
    WHERE t.id=ticket_reservations.trip_id
      AND t.company_id=public.busnex_company_id()
      AND r.company_id=t.company_id
      AND r.region='NB'
      AND public.busnex_user_role()='nb_sub_manager'
      AND public.busnex_user_region()='NB'
  )
);

DROP POLICY IF EXISTS ticket_reservation_seats_nb_sub_manager_select ON public.ticket_reservation_seats;
CREATE POLICY ticket_reservation_seats_nb_sub_manager_select ON public.ticket_reservation_seats
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.ticket_reservations tr
    JOIN public.trips t ON t.id=tr.trip_id
    JOIN public.routes r ON r.id=t.route_id
    WHERE tr.id=ticket_reservation_seats.reservation_id
      AND t.company_id=public.busnex_company_id()
      AND r.company_id=t.company_id
      AND r.region='NB'
      AND public.busnex_user_role()='nb_sub_manager'
      AND public.busnex_user_region()='NB'
  )
);

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
BEGIN
  IF auth.uid() IS NULL
     OR public.busnex_user_role() <> 'nb_sub_manager'
     OR public.busnex_user_region() <> 'NB' THEN
    RAISE EXCEPTION 'শুধু NB Sub Manager এই কাজ করতে পারবেন';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.trips t
    JOIN public.routes r ON r.id=t.route_id
    WHERE t.id=p_trip_id
      AND t.company_id=public.busnex_company_id()
      AND r.company_id=t.company_id
      AND r.region='NB'
  ) THEN
    RAISE EXCEPTION 'এই NB Trip-এর অনুমতি পাওয়া যায়নি';
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
     OR public.busnex_user_region() <> 'NB' THEN
    RAISE EXCEPTION 'শুধু NB Sub Manager Reservation Cancel করতে পারবেন';
  END IF;

  SELECT tr.status INTO v_status
  FROM public.ticket_reservations tr
  JOIN public.trips t ON t.id=tr.trip_id
  JOIN public.routes r ON r.id=t.route_id
  WHERE tr.id=p_reservation_id
    AND t.company_id=public.busnex_company_id()
    AND r.company_id=t.company_id
    AND r.region='NB'
  FOR UPDATE OF tr;

  IF NOT FOUND THEN RAISE EXCEPTION 'NB Reservation পাওয়া যায়নি অথবা অনুমতি নেই'; END IF;
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

REVOKE ALL ON FUNCTION public.busnex_nb_set_trip_seat_block(uuid,text,boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_nb_set_trip_seat_block(uuid,text,boolean) TO authenticated;
REVOKE ALL ON FUNCTION public.busnex_nb_cancel_reservation(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_nb_cancel_reservation(uuid) TO authenticated;
