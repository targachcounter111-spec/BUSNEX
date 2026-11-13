-- BUSNEX: enforce BUS OFF at the database boundary as well as in the UI.
-- This protects ticket sales and temporary holds even if a client bypasses the frontend.

CREATE OR REPLACE FUNCTION public.busnex_guard_bus_off_write()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_is_active boolean;
  v_trip_status text;
BEGIN
  IF TG_TABLE_NAME = 'trip_seats' AND NEW.status IS DISTINCT FROM 'held' THEN
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'tickets' AND NEW.status IS DISTINCT FROM 'sold' THEN
    RETURN NEW;
  END IF;

  SELECT tr.is_active, tr.status
    INTO v_is_active, v_trip_status
  FROM public.trips AS tr
  WHERE tr.id = NEW.trip_id
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Trip not found';
  END IF;

  IF v_is_active IS DISTINCT FROM true OR v_trip_status IS DISTINCT FROM 'scheduled' THEN
    RAISE EXCEPTION 'BUS OFF — TICKET SALE STOPPED';
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS busnex_guard_bus_off_ticket_insert ON public.tickets;
CREATE TRIGGER busnex_guard_bus_off_ticket_insert
BEFORE INSERT ON public.tickets
FOR EACH ROW
EXECUTE FUNCTION public.busnex_guard_bus_off_write();

DROP TRIGGER IF EXISTS busnex_guard_bus_off_seat_hold ON public.trip_seats;
CREATE TRIGGER busnex_guard_bus_off_seat_hold
BEFORE UPDATE OF status ON public.trip_seats
FOR EACH ROW
EXECUTE FUNCTION public.busnex_guard_bus_off_write();

REVOKE ALL ON FUNCTION public.busnex_guard_bus_off_write() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.busnex_guard_bus_off_write() FROM anon;
