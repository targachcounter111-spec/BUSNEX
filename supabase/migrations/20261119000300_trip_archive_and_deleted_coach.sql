-- BUSNEX: soft-archive trips without deleting ticket, seat, or billing history.
BEGIN;

ALTER TABLE public.trips
  ADD COLUMN IF NOT EXISTS archived_at timestamptz,
  ADD COLUMN IF NOT EXISTS archived_by uuid REFERENCES auth.users(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS trips_archived_company_idx
  ON public.trips(company_id, archived_at)
  WHERE archived_at IS NOT NULL;

CREATE OR REPLACE FUNCTION public.busnex_archive_trips(p_trip_ids uuid[])
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_role text;
  v_company_id uuid;
  v_requested integer;
  v_allowed integer;
  v_updated integer;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Login required'; END IF;
  v_role := public.busnex_user_role();
  v_company_id := public.busnex_company_id();

  IF v_role NOT IN ('super_admin','company_manager','nb_sub_manager','dhaka_sub_manager') THEN
    RAISE EXCEPTION 'Archive করার অনুমতি নেই';
  END IF;
  IF p_trip_ids IS NULL OR cardinality(p_trip_ids) < 1 OR cardinality(p_trip_ids) > 100 THEN
    RAISE EXCEPTION 'একবারে ১ থেকে ১০০টি Schedule নির্বাচন করুন';
  END IF;
  SELECT count(DISTINCT x.id)::integer INTO v_requested
  FROM unnest(p_trip_ids) AS x(id) WHERE x.id IS NOT NULL;
  IF v_requested <> cardinality(p_trip_ids) THEN
    RAISE EXCEPTION 'Trip ID তালিকায় NULL বা Duplicate আছে';
  END IF;

  SELECT count(*)::integer INTO v_allowed
  FROM public.trips t
  JOIN public.routes r ON r.id=t.route_id AND r.company_id=t.company_id
  WHERE t.id = ANY(p_trip_ids)
    AND t.archived_at IS NULL
    AND t.status = 'scheduled'
    AND t.departure_time >= now()
    AND (
      v_role = 'super_admin'
      OR (v_role = 'company_manager' AND t.company_id=v_company_id)
      OR (v_role IN ('nb_sub_manager','dhaka_sub_manager')
          AND t.company_id=v_company_id
          AND public.busnex_is_region_sub_manager(r.region))
    );

  IF v_allowed <> v_requested THEN
    RAISE EXCEPTION 'নির্বাচিত Schedule-এর কিছুতে অনুমতি নেই, অথবা Schedule আর Active নয়। কোনো Schedule Archive করা হয়নি।';
  END IF;

  UPDATE public.trips t
  SET archived_at=now(), archived_by=auth.uid()
  WHERE t.id = ANY(p_trip_ids) AND t.archived_at IS NULL;
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated <> v_requested THEN RAISE EXCEPTION 'সব Schedule Archive করা যায়নি'; END IF;
  RETURN v_updated;
END;
$function$;

CREATE OR REPLACE FUNCTION public.busnex_restore_archived_trip(p_trip_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_role text;
  v_company_id uuid;
  v_region text;
  v_trip public.trips%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Login required'; END IF;
  v_role := public.busnex_user_role();
  v_company_id := public.busnex_company_id();
  IF v_role NOT IN ('super_admin','company_manager','nb_sub_manager','dhaka_sub_manager') THEN
    RAISE EXCEPTION 'Restore করার অনুমতি নেই';
  END IF;

  SELECT t.*, r.region INTO v_trip, v_region
  FROM public.trips t JOIN public.routes r ON r.id=t.route_id
  WHERE t.id=p_trip_id AND t.archived_at IS NOT NULL
    AND (
      v_role='super_admin'
      OR (v_role='company_manager' AND t.company_id=v_company_id)
      OR (v_role IN ('nb_sub_manager','dhaka_sub_manager')
          AND t.company_id=v_company_id
          AND public.busnex_is_region_sub_manager(r.region))
    )
  FOR UPDATE OF t;
  IF NOT FOUND THEN RAISE EXCEPTION 'Archived Schedule পাওয়া যায়নি অথবা অনুমতি নেই'; END IF;
  UPDATE public.trips SET archived_at=NULL, archived_by=NULL WHERE id=p_trip_id;
  RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION public.busnex_get_archived_trip_details(p_trip_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_role text;
  v_company_id uuid;
  v_result jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Login required'; END IF;
  v_role := public.busnex_user_role();
  v_company_id := public.busnex_company_id();
  IF v_role NOT IN ('super_admin','company_manager','nb_sub_manager','dhaka_sub_manager') THEN
    RAISE EXCEPTION 'Archived Coach Details দেখার অনুমতি নেই';
  END IF;

  SELECT jsonb_build_object(
    'trip',to_jsonb(t),
    'bus',to_jsonb(b),
    'route',to_jsonb(r),
    'seats',COALESCE((SELECT jsonb_agg(to_jsonb(ts) ORDER BY ts.seat_number)
                     FROM public.trip_seats ts WHERE ts.trip_id=t.id),'[]'::jsonb),
    'tickets',COALESCE((SELECT jsonb_agg(to_jsonb(tk) ORDER BY tk.seat_number,tk.created_at)
                        FROM public.tickets tk WHERE tk.trip_id=t.id),'[]'::jsonb),
    'boarding_points',COALESCE((SELECT jsonb_agg(to_jsonb(bp) ORDER BY bp.point_order)
                                FROM public.trip_boarding_points bp WHERE bp.trip_id=t.id),'[]'::jsonb),
    'stops',COALESCE((SELECT jsonb_agg(to_jsonb(st) ORDER BY st.stop_order)
                      FROM public.trip_stops st WHERE st.trip_id=t.id),'[]'::jsonb)
  )
  INTO v_result
  FROM public.trips t
  LEFT JOIN public.buses b ON b.id=t.bus_id
  LEFT JOIN public.routes r ON r.id=t.route_id
  WHERE t.id=p_trip_id AND t.archived_at IS NOT NULL
    AND (
      v_role='super_admin'
      OR (v_role='company_manager' AND t.company_id=v_company_id)
      OR (v_role IN ('nb_sub_manager','dhaka_sub_manager')
          AND t.company_id=v_company_id
          AND public.busnex_is_region_sub_manager(r.region))
    );

  IF v_result IS NULL THEN RAISE EXCEPTION 'Archived Coach পাওয়া যায়নি অথবা অনুমতি নেই'; END IF;
  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.busnex_block_archived_trip_activity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE v_trip_id uuid;
BEGIN
  IF TG_TABLE_NAME='tickets' THEN
    IF NEW.status='sold' THEN v_trip_id:=NEW.trip_id; END IF;
  ELSIF TG_TABLE_NAME='ticket_reservations' THEN
    v_trip_id:=NEW.trip_id;
  ELSIF TG_TABLE_NAME='trip_seats' THEN
    IF NEW.status='held' OR NEW.reservation_id IS NOT NULL THEN v_trip_id:=NEW.trip_id; END IF;
  END IF;

  IF v_trip_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.trips t WHERE t.id=v_trip_id AND t.archived_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'এই Coach Archive করা হয়েছে; নতুন Ticket, Reservation বা Seat Hold করা যাবে না';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS busnex_block_archived_ticket_sale ON public.tickets;
CREATE TRIGGER busnex_block_archived_ticket_sale
BEFORE INSERT OR UPDATE OF status ON public.tickets
FOR EACH ROW EXECUTE FUNCTION public.busnex_block_archived_trip_activity();

DROP TRIGGER IF EXISTS busnex_block_archived_reservation ON public.ticket_reservations;
CREATE TRIGGER busnex_block_archived_reservation
BEFORE INSERT OR UPDATE OF trip_id ON public.ticket_reservations
FOR EACH ROW EXECUTE FUNCTION public.busnex_block_archived_trip_activity();

DROP TRIGGER IF EXISTS busnex_block_archived_seat_activity ON public.trip_seats;
CREATE TRIGGER busnex_block_archived_seat_activity
BEFORE INSERT OR UPDATE OF status,reservation_id ON public.trip_seats
FOR EACH ROW EXECUTE FUNCTION public.busnex_block_archived_trip_activity();

REVOKE ALL ON FUNCTION public.busnex_archive_trips(uuid[]) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.busnex_restore_archived_trip(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.busnex_get_archived_trip_details(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.busnex_block_archived_trip_activity() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.busnex_archive_trips(uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.busnex_restore_archived_trip(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.busnex_get_archived_trip_details(uuid) TO authenticated;

COMMIT;
