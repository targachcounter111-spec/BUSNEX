-- BUSNEX ticket cancellation with per-counter permission and audit history.
BEGIN;

CREATE TABLE IF NOT EXISTS public.counter_ticket_cancel_permissions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  counter_id uuid NOT NULL REFERENCES public.counters(id) ON DELETE CASCADE,
  granted_by uuid REFERENCES auth.users(id),
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(counter_id)
);

CREATE TABLE IF NOT EXISTS public.ticket_cancellation_audit (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_id uuid NOT NULL,
  trip_id uuid NOT NULL,
  seat_number text NOT NULL,
  passenger_name text,
  passenger_phone text,
  ticket_price numeric,
  cancelled_by uuid REFERENCES auth.users(id),
  cancelled_at timestamptz NOT NULL DEFAULT now(),
  cancelled_by_role text NOT NULL
);

ALTER TABLE public.counter_ticket_cancel_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ticket_cancellation_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.counter_ticket_cancel_permissions FROM anon, authenticated;
REVOKE ALL ON public.ticket_cancellation_audit FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.busnex_can_cancel_tickets()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE v_role text; v_counter_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RETURN false; END IF;
  v_role:=public.busnex_user_role();
  IF v_role IN ('super_admin','company_manager') THEN RETURN true; END IF;
  IF v_role<>'counter_operator' THEN RETURN false; END IF;
  v_counter_id:=public.busnex_counter_id();
  RETURN EXISTS(
    SELECT 1 FROM public.counter_ticket_cancel_permissions p
    WHERE p.counter_id=v_counter_id
      AND p.company_id=public.busnex_company_id()
      AND p.is_active=true
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.busnex_grant_ticket_cancel_permission(p_counter_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE v_role text; v_company_id uuid; v_counter_company_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Login required'; END IF;
  v_role:=public.busnex_user_role();
  v_company_id:=public.busnex_company_id();
  IF v_role NOT IN ('super_admin','company_manager') THEN RAISE EXCEPTION 'Only Manager or Super Admin can grant permission'; END IF;
  SELECT c.company_id INTO v_counter_company_id FROM public.counters c WHERE c.id=p_counter_id;
  IF v_counter_company_id IS NULL THEN RAISE EXCEPTION 'Counter not found'; END IF;
  IF v_role='company_manager' AND v_counter_company_id IS DISTINCT FROM v_company_id THEN
    RAISE EXCEPTION 'Cannot manage another company counter';
  END IF;
  INSERT INTO public.counter_ticket_cancel_permissions(company_id,counter_id,granted_by,is_active,created_at,updated_at)
  VALUES(v_counter_company_id,p_counter_id,auth.uid(),true,now(),now())
  ON CONFLICT(counter_id) DO UPDATE SET company_id=EXCLUDED.company_id,granted_by=auth.uid(),is_active=true,updated_at=now();
  RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION public.busnex_revoke_ticket_cancel_permission(p_counter_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE v_role text; v_company_id uuid; v_counter_company_id uuid; v_count integer;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Login required'; END IF;
  v_role:=public.busnex_user_role();
  v_company_id:=public.busnex_company_id();
  IF v_role NOT IN ('super_admin','company_manager') THEN RAISE EXCEPTION 'Only Manager or Super Admin can revoke permission'; END IF;
  SELECT c.company_id INTO v_counter_company_id FROM public.counters c WHERE c.id=p_counter_id;
  IF v_counter_company_id IS NULL THEN RAISE EXCEPTION 'Counter not found'; END IF;
  IF v_role='company_manager' AND v_counter_company_id IS DISTINCT FROM v_company_id THEN
    RAISE EXCEPTION 'Cannot manage another company counter';
  END IF;
  UPDATE public.counter_ticket_cancel_permissions SET is_active=false,updated_at=now()
  WHERE counter_id=p_counter_id AND company_id=v_counter_company_id AND is_active=true;
  GET DIAGNOSTICS v_count=ROW_COUNT;
  RETURN v_count>0;
END;
$function$;

CREATE OR REPLACE FUNCTION public.busnex_cancel_tickets(p_ticket_ids uuid[])
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_role text; v_company_id uuid; v_counter_id uuid; v_expected integer; v_found integer;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Login required'; END IF;
  IF p_ticket_ids IS NULL OR cardinality(p_ticket_ids)<1 OR cardinality(p_ticket_ids)>8 THEN
    RAISE EXCEPTION 'Invalid Ticket selection';
  END IF;
  IF (SELECT count(DISTINCT x) FROM unnest(p_ticket_ids) x)<>cardinality(p_ticket_ids) THEN
    RAISE EXCEPTION 'Duplicate Ticket ID';
  END IF;
  v_role:=public.busnex_user_role();
  v_company_id:=public.busnex_company_id();
  v_counter_id:=public.busnex_counter_id();
  IF v_role NOT IN ('super_admin','company_manager','counter_operator') THEN
    RAISE EXCEPTION 'Permission denied';
  END IF;

  SELECT count(*) INTO v_found
  FROM public.tickets tk JOIN public.trips tr ON tr.id=tk.trip_id
  WHERE tk.id=ANY(p_ticket_ids) AND tk.status='sold'
    AND (
      v_role='super_admin'
      OR (v_role='company_manager' AND tr.company_id=v_company_id)
      OR (v_role='counter_operator' AND tr.company_id=v_company_id AND tk.counter_id=v_counter_id
          AND EXISTS(SELECT 1 FROM public.counter_ticket_cancel_permissions p
            WHERE p.counter_id=v_counter_id AND p.company_id=v_company_id AND p.is_active=true))
    );
  v_expected:=cardinality(p_ticket_ids);
  IF v_found<>v_expected THEN RAISE EXCEPTION 'Ticket পাওয়া যায়নি, ইতিমধ্যে Cancel হয়েছে অথবা আপনার Permission নেই'; END IF;

  INSERT INTO public.ticket_cancellation_audit(ticket_id,trip_id,seat_number,passenger_name,passenger_phone,ticket_price,cancelled_by,cancelled_by_role)
  SELECT tk.id,tk.trip_id,tk.seat_number,tk.passenger_name,tk.passenger_phone,tk.ticket_price,auth.uid(),v_role
  FROM public.tickets tk WHERE tk.id=ANY(p_ticket_ids) AND tk.status='sold';

  UPDATE public.tickets SET status='cancelled'
  WHERE id=ANY(p_ticket_ids) AND status='sold';

  UPDATE public.trip_seats ts
  SET status='available',reservation_id=NULL,hold_until=NULL,held_by=NULL,held_counter_id=NULL
  FROM public.tickets tk
  WHERE tk.id=ANY(p_ticket_ids) AND tk.trip_id=ts.trip_id
    AND tk.seat_number=ts.seat_number AND tk.status='cancelled'
    AND ts.status IN ('sold','male_sold','female_sold','sold_male','sold_female');

  RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION public.busnex_can_cancel_tickets() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_can_cancel_tickets() TO authenticated;
REVOKE ALL ON FUNCTION public.busnex_grant_ticket_cancel_permission(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_grant_ticket_cancel_permission(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.busnex_revoke_ticket_cancel_permission(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_revoke_ticket_cancel_permission(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.busnex_cancel_tickets(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_cancel_tickets(uuid[]) TO authenticated;

COMMIT;
