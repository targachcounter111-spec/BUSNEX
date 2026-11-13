-- BUSNEX MANUAL DATABASE SETUP
-- Reservation has no fee. Only tickets with status='sold' are billed at BDT 0.50 per seat.
-- Apply this complete script once in Supabase SQL Editor on the target project.
-- This is a manual bundle of the ordered migration files below.

BEGIN;

-- ===== 20261113000100_secure_ticket_details.sql =====
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

-- ===== 20261113000200_reservation_permission_controls.sql =====
-- BUSNEX reservation permission controls.
-- Managers can grant/revoke permissions only for counters in their own company.
-- Super Admin can manage permissions for any existing counter.
CREATE OR REPLACE FUNCTION public.busnex_grant_reservation_permission(
  p_counter_id uuid,
  p_reservation_type text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_role text;
  v_company_id uuid;
  v_counter_company_id uuid;
  v_permission_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Login required';
  END IF;

  v_role := public.busnex_user_role();
  v_company_id := public.busnex_company_id();

  IF v_role IS NULL OR v_role NOT IN ('super_admin', 'company_manager') THEN
    RAISE EXCEPTION 'Only Manager or Super Admin can grant permissions';
  END IF;

  IF p_reservation_type IS NULL OR p_reservation_type NOT IN ('standard', 'vip') THEN
    RAISE EXCEPTION 'Invalid reservation type';
  END IF;

  SELECT c.company_id INTO v_counter_company_id
  FROM public.counters c
  WHERE c.id = p_counter_id;

  IF v_counter_company_id IS NULL THEN
    RAISE EXCEPTION 'Counter not found';
  END IF;

  IF v_role = 'company_manager'
     AND (v_company_id IS NULL OR v_counter_company_id <> v_company_id) THEN
    RAISE EXCEPTION 'Cannot manage another company counter';
  END IF;

  -- Serialize grants for this counter/type without assuming a unique index exists.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext(p_counter_id::text),
    pg_catalog.hashtext(p_reservation_type)
  );

  UPDATE public.counter_reservation_permissions AS crp
  SET company_id = v_counter_company_id,
      granted_by = auth.uid(),
      is_active = true,
      updated_at = now()
  WHERE crp.id = (
    SELECT existing.id
    FROM public.counter_reservation_permissions AS existing
    WHERE existing.counter_id = p_counter_id
      AND existing.reservation_type = p_reservation_type
    ORDER BY existing.updated_at DESC NULLS LAST, existing.created_at DESC NULLS LAST
    LIMIT 1
  )
  RETURNING crp.id INTO v_permission_id;

  IF v_permission_id IS NULL THEN
    INSERT INTO public.counter_reservation_permissions
      (company_id, counter_id, granted_by, reservation_type, is_active, created_at, updated_at)
    VALUES
      (v_counter_company_id, p_counter_id, auth.uid(), p_reservation_type, true, now(), now())
    RETURNING id INTO v_permission_id;
  END IF;

  RETURN v_permission_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.busnex_revoke_reservation_permission(
  p_counter_id uuid,
  p_reservation_type text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_role text;
  v_company_id uuid;
  v_counter_company_id uuid;
  v_rows integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Login required';
  END IF;

  v_role := public.busnex_user_role();
  v_company_id := public.busnex_company_id();

  IF v_role IS NULL OR v_role NOT IN ('super_admin', 'company_manager') THEN
    RAISE EXCEPTION 'Only Manager or Super Admin can revoke permissions';
  END IF;

  IF p_reservation_type IS NULL OR p_reservation_type NOT IN ('standard', 'vip') THEN
    RAISE EXCEPTION 'Invalid reservation type';
  END IF;

  SELECT c.company_id INTO v_counter_company_id
  FROM public.counters c
  WHERE c.id = p_counter_id;

  IF v_counter_company_id IS NULL THEN
    RAISE EXCEPTION 'Counter not found';
  END IF;

  IF v_role = 'company_manager'
     AND (v_company_id IS NULL OR v_counter_company_id <> v_company_id) THEN
    RAISE EXCEPTION 'Cannot manage another company counter';
  END IF;

  UPDATE public.counter_reservation_permissions
  SET is_active = false, updated_at = now()
  WHERE counter_id = p_counter_id
    AND reservation_type = p_reservation_type
    AND company_id = v_counter_company_id
    AND is_active = true;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows > 0;
END;
$function$;

REVOKE ALL ON FUNCTION public.busnex_grant_reservation_permission(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.busnex_grant_reservation_permission(uuid, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.busnex_grant_reservation_permission(uuid, text) TO authenticated;

REVOKE ALL ON FUNCTION public.busnex_revoke_reservation_permission(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.busnex_revoke_reservation_permission(uuid, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.busnex_revoke_reservation_permission(uuid, text) TO authenticated;

-- ===== 20261113000300_late_departure_past_date_confirmation.sql =====
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


-- ===== 20261113000400_enforce_bus_off_server_side.sql =====
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

-- ===== 20261113000500_atomic_group_ticket_sale.sql =====
-- BUSNEX: atomic multi-seat ticket sale (maximum 8 seats).
-- A failure on any seat aborts the entire RPC transaction; no partial group sale.
CREATE OR REPLACE FUNCTION public.busnex_sell_tickets_batch(
  p_trip_id uuid,
  p_seat_numbers text[],
  p_passenger_name text,
  p_passenger_phone text,
  p_boarding_stop_id uuid,
  p_dropping_stop_id uuid,
  p_passenger_gender text,
  p_confirm_past_date boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO ''
AS $function$
DECLARE
  v_seat text;
  v_result jsonb := '[]'::jsonb;
  v_ticket jsonb;
  v_count integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Login required';
  END IF;

  IF p_seat_numbers IS NULL THEN
    RAISE EXCEPTION 'কমপক্ষে একটি Seat নির্বাচন করুন';
  END IF;

  v_count := cardinality(p_seat_numbers);
  IF v_count < 1 OR v_count > 8 THEN
    RAISE EXCEPTION 'একসঙ্গে সর্বোচ্চ ৮টি Seat বিক্রি করা যাবে';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM unnest(p_seat_numbers) AS requested(seat_number)
    WHERE requested.seat_number IS NULL
       OR btrim(requested.seat_number) = ''
  ) THEN
    RAISE EXCEPTION 'Invalid seat number';
  END IF;

  IF (SELECT count(DISTINCT btrim(requested.seat_number)) FROM unnest(p_seat_numbers) AS requested(seat_number)) <> v_count THEN
    RAISE EXCEPTION 'একই Seat একাধিকবার নির্বাচন করা হয়েছে';
  END IF;

  FOR v_seat IN
    SELECT btrim(requested.seat_number)
    FROM unnest(p_seat_numbers) AS requested(seat_number)
    ORDER BY btrim(requested.seat_number)
  LOOP
    v_ticket := pg_catalog.to_jsonb(public.busnex_sell_ticket(
      p_trip_id,
      v_seat,
      p_passenger_name,
      p_passenger_phone,
      p_boarding_stop_id,
      p_dropping_stop_id,
      p_passenger_gender,
      COALESCE(p_confirm_past_date, false)
    ));

    v_result := v_result || jsonb_build_array(
      jsonb_build_object('seat_number', v_seat, 'result', v_ticket)
    );
  END LOOP;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.busnex_sell_tickets_batch(uuid, text[], text, text, uuid, uuid, text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.busnex_sell_tickets_batch(uuid, text[], text, text, uuid, uuid, text, boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.busnex_sell_tickets_batch(uuid, text[], text, text, uuid, uuid, text, boolean) TO authenticated;

-- ===== 20261113000600_company_billing_ledger.sql =====
-- BUSNEX: monthly company billing invoices and immutable payment history.
-- Service charge: BDT 0.50 per ticket currently sold in the billing period.
-- Cancelled tickets are excluded. Period boundaries use Asia/Dhaka local time.

CREATE TABLE IF NOT EXISTS public.company_billing_invoices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  period_start date NOT NULL,
  period_end date NOT NULL,
  due_date date NOT NULL,
  sold_seat_count integer NOT NULL DEFAULT 0 CHECK (sold_seat_count >= 0),
  rate_per_seat numeric(12,2) NOT NULL DEFAULT 0.50 CHECK (rate_per_seat >= 0),
  amount numeric(12,2) NOT NULL DEFAULT 0 CHECK (amount >= 0),
  paid_amount numeric(12,2) NOT NULL DEFAULT 0 CHECK (paid_amount >= 0),
  status text NOT NULL DEFAULT 'due' CHECK (status IN ('due','partial','paid')),
  created_by uuid REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT company_billing_invoice_period_valid CHECK (period_end > period_start),
  CONSTRAINT company_billing_invoice_paid_not_over_amount CHECK (paid_amount <= amount),
  CONSTRAINT company_billing_invoice_company_period_unique UNIQUE (company_id, period_start, period_end)
);

CREATE TABLE IF NOT EXISTS public.company_billing_payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id uuid NOT NULL REFERENCES public.company_billing_invoices(id) ON DELETE RESTRICT,
  amount numeric(12,2) NOT NULL CHECK (amount > 0),
  payment_reference text,
  note text,
  received_by uuid REFERENCES auth.users(id),
  received_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS company_billing_invoices_company_period_idx
  ON public.company_billing_invoices(company_id, period_start DESC);
CREATE INDEX IF NOT EXISTS company_billing_payments_invoice_idx
  ON public.company_billing_payments(invoice_id, received_at DESC);

ALTER TABLE public.company_billing_invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.company_billing_payments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS busnex_billing_invoice_select ON public.company_billing_invoices;
CREATE POLICY busnex_billing_invoice_select
ON public.company_billing_invoices
FOR SELECT TO authenticated
USING (
  public.busnex_user_role() = 'super_admin'
  OR (
    public.busnex_user_role() = 'company_manager'
    AND company_id = public.busnex_company_id()
  )
);

DROP POLICY IF EXISTS busnex_billing_payment_select ON public.company_billing_payments;
CREATE POLICY busnex_billing_payment_select
ON public.company_billing_payments
FOR SELECT TO authenticated
USING (
  public.busnex_user_role() = 'super_admin'
  OR EXISTS (
    SELECT 1
    FROM public.company_billing_invoices AS invoice
    WHERE invoice.id = invoice_id
      AND invoice.company_id = public.busnex_company_id()
      AND public.busnex_user_role() = 'company_manager'
  )
);

REVOKE ALL ON public.company_billing_invoices FROM anon, authenticated;
REVOKE ALL ON public.company_billing_payments FROM anon, authenticated;
GRANT SELECT ON public.company_billing_invoices TO authenticated;
GRANT SELECT ON public.company_billing_payments TO authenticated;

CREATE OR REPLACE FUNCTION public.busnex_generate_company_invoice(
  p_company_id uuid,
  p_period_start date,
  p_period_end date,
  p_due_date date
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_invoice_id uuid;
  v_count integer;
  v_amount numeric(12,2);
BEGIN
  IF auth.uid() IS NULL OR public.busnex_user_role() IS DISTINCT FROM 'super_admin' THEN
    RAISE EXCEPTION 'Only Super Admin can generate invoices';
  END IF;
  IF p_company_id IS NULL OR p_period_start IS NULL OR p_period_end IS NULL
     OR p_due_date IS NULL OR p_period_end <= p_period_start
     OR p_period_start <> date_trunc('month', p_period_start)::date THEN
    RAISE EXCEPTION 'Invalid invoice company, period, or due date';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.companies c WHERE c.id = p_company_id) THEN
    RAISE EXCEPTION 'Company not found';
  END IF;

  SELECT count(*)::integer
    INTO v_count
  FROM public.tickets tk
  JOIN public.trips tr ON tr.id = tk.trip_id
  WHERE tr.company_id = p_company_id
    AND tk.status = 'sold'
    AND tk.created_at >= (p_period_start::timestamp AT TIME ZONE 'Asia/Dhaka')
    AND tk.created_at < (p_period_end::timestamp AT TIME ZONE 'Asia/Dhaka');

  v_amount := round(v_count * 0.50, 2);

  INSERT INTO public.company_billing_invoices
    (company_id, period_start, period_end, due_date, sold_seat_count,
     rate_per_seat, amount, paid_amount, status, created_by, created_at, updated_at)
  VALUES
    (p_company_id, p_period_start, p_period_end, p_due_date, v_count,
     0.50, v_amount, 0, CASE WHEN v_amount = 0 THEN 'paid' ELSE 'due' END,
     auth.uid(), now(), now())
  ON CONFLICT (company_id, period_start, period_end)
  DO UPDATE SET
    due_date = EXCLUDED.due_date,
    sold_seat_count = EXCLUDED.sold_seat_count,
    amount = EXCLUDED.amount,
    status = CASE WHEN EXCLUDED.amount = 0 THEN 'paid' ELSE 'due' END,
    updated_at = now()
  WHERE public.company_billing_invoices.paid_amount = 0
  RETURNING id INTO v_invoice_id;

  IF v_invoice_id IS NULL THEN
    RAISE EXCEPTION 'এই Invoice-এ Payment নেওয়া হয়েছে; Paid Invoice পুনরায় হিসাব করা যাবে না';
  END IF;
  RETURN v_invoice_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.busnex_record_company_payment(
  p_invoice_id uuid,
  p_amount numeric,
  p_payment_reference text DEFAULT NULL,
  p_note text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_invoice public.company_billing_invoices%ROWTYPE;
  v_payment_id uuid;
  v_new_paid numeric(12,2);
BEGIN
  IF auth.uid() IS NULL OR public.busnex_user_role() <> 'super_admin' THEN
    RAISE EXCEPTION 'Only Super Admin can record payments';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 OR p_amount <> round(p_amount, 2) THEN
    RAISE EXCEPTION 'Payment amount must be positive and have at most two decimal places';
  END IF;

  SELECT * INTO v_invoice
  FROM public.company_billing_invoices
  WHERE id = p_invoice_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice not found'; END IF;
  v_new_paid := v_invoice.paid_amount + p_amount;
  IF v_new_paid > v_invoice.amount THEN
    RAISE EXCEPTION 'Payment exceeds outstanding due amount';
  END IF;

  INSERT INTO public.company_billing_payments
    (invoice_id, amount, payment_reference, note, received_by)
  VALUES
    (p_invoice_id, p_amount, NULLIF(btrim(p_payment_reference), ''),
     NULLIF(btrim(p_note), ''), auth.uid())
  RETURNING id INTO v_payment_id;

  UPDATE public.company_billing_invoices
  SET paid_amount = v_new_paid,
      status = CASE WHEN v_new_paid = amount THEN 'paid' ELSE 'partial' END,
      updated_at = now()
  WHERE id = p_invoice_id;

  RETURN v_payment_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.busnex_generate_company_invoice(uuid, date, date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_generate_company_invoice(uuid, date, date, date) TO authenticated;
REVOKE ALL ON FUNCTION public.busnex_record_company_payment(uuid, numeric, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_record_company_payment(uuid, numeric, text, text) TO authenticated;

-- ===== 20261113000700_reservation_lifecycle.sql =====
-- BUSNEX: secure reservation lifecycle.
-- Reservation permissions are granted per counter and type.
-- Standard expires five minutes before departure; VIP has no expiry by default.
-- Confirmation is tracked separately while status remains active, so existing
-- seat-sale protection that checks active reservations continues to protect seats.
-- Reservation has NO fee. Billing is charged only for actually sold tickets,
-- at BDT 0.50 per sold seat through the separate company billing ledger.
ALTER TABLE public.ticket_reservations
  ADD COLUMN IF NOT EXISTS confirmed_at timestamptz;

CREATE OR REPLACE FUNCTION public.busnex_create_reservation(
  p_trip_id uuid,
  p_reservation_type text,
  p_seat_numbers text[],
  p_passenger_name text,
  p_passenger_phone text,
  p_passenger_gender text,
  p_boarding_stop_id uuid,
  p_dropping_stop_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_role text;
  v_company_id uuid;
  v_counter_id uuid;
  v_trip public.trips%ROWTYPE;
  v_reservation_id uuid;
  v_expiry timestamptz;
  v_seat text;
  v_seat_row public.trip_seats%ROWTYPE;
  v_seat_count integer;
  v_board_order integer;
  v_drop_order integer;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Login required'; END IF;
  v_role := public.busnex_user_role();
  v_company_id := public.busnex_company_id();
  v_counter_id := public.busnex_counter_id();

  IF v_role IS DISTINCT FROM 'counter_operator' OR v_counter_id IS NULL THEN
    RAISE EXCEPTION 'শুধু নির্ধারিত Counter Operator Reservation তৈরি করতে পারবেন';
  END IF;
  IF p_reservation_type IS NULL OR p_reservation_type NOT IN ('standard','vip') THEN
    RAISE EXCEPTION 'Invalid reservation type';
  END IF;
  IF p_passenger_name IS NULL OR btrim(p_passenger_name) = ''
     OR p_passenger_phone IS NULL OR btrim(p_passenger_phone) = ''
     OR p_passenger_gender IS NULL OR p_passenger_gender NOT IN ('Male','Female') THEN
    RAISE EXCEPTION 'Passenger name, phone and gender are required';
  END IF;
  IF p_seat_numbers IS NULL OR cardinality(p_seat_numbers) < 1 OR cardinality(p_seat_numbers) > 8 THEN
    RAISE EXCEPTION 'একসঙ্গে ১ থেকে ৮টি Seat Reservation করা যাবে';
  END IF;
  IF EXISTS (
    SELECT 1 FROM unnest(p_seat_numbers) AS s(seat)
    WHERE s.seat IS NULL OR btrim(s.seat) = ''
  ) OR (SELECT count(DISTINCT btrim(s.seat)) FROM unnest(p_seat_numbers) AS s(seat)) <> cardinality(p_seat_numbers) THEN
    RAISE EXCEPTION 'Seat list invalid or contains duplicates';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.counter_reservation_permissions p
    WHERE p.counter_id = v_counter_id
      AND p.company_id = v_company_id
      AND p.reservation_type = p_reservation_type
      AND p.is_active = true
  ) THEN
    RAISE EXCEPTION 'এই Counter-এর জন্য এই ধরনের Reservation Permission নেই';
  END IF;

  SELECT * INTO v_trip
  FROM public.trips t
  WHERE t.id = p_trip_id
    AND t.company_id = v_company_id
    AND t.is_active = true
    AND t.status = 'scheduled'
  FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Trip পাওয়া যায়নি অথবা বন্ধ রয়েছে'; END IF;
  IF v_trip.departure_time <= now() THEN RAISE EXCEPTION 'Departure Time পার হয়ে গেছে'; END IF;

  IF p_reservation_type = 'standard' THEN
    v_expiry := v_trip.departure_time - interval '5 minutes';
    IF v_expiry <= now() THEN RAISE EXCEPTION 'Standard Reservation-এর সময় শেষ'; END IF;
  ELSE
    v_expiry := NULL;
  END IF;

  SELECT ts.stop_order INTO v_board_order
  FROM public.trip_stops ts
  WHERE ts.id = p_boarding_stop_id AND ts.trip_id = p_trip_id AND ts.is_active = true;
  SELECT ts.stop_order INTO v_drop_order
  FROM public.trip_stops ts
  WHERE ts.id = p_dropping_stop_id AND ts.trip_id = p_trip_id AND ts.is_active = true;
  IF v_board_order IS NULL OR v_drop_order IS NULL OR v_board_order >= v_drop_order THEN
    RAISE EXCEPTION 'Boarding ও Dropping Stop সঠিকভাবে নির্বাচন করুন';
  END IF;

  -- Lock all requested inventory rows in stable order to prevent racing reservations.
  FOR v_seat IN
    SELECT btrim(s.seat) FROM unnest(p_seat_numbers) AS s(seat) ORDER BY btrim(s.seat)
  LOOP
    SELECT ts.* INTO v_seat_row
    FROM public.trip_seats ts
    WHERE ts.trip_id = p_trip_id AND ts.seat_number = v_seat
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Seat % পাওয়া যায়নি', v_seat; END IF;
    IF v_seat_row.status NOT IN ('available','held') THEN
      RAISE EXCEPTION 'Seat % এখন Reservation-এর জন্য Available নয়', v_seat;
    END IF;
    IF v_seat_row.status = 'held'
       AND v_seat_row.hold_until > now()
       AND v_seat_row.held_by IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION 'Seat % অন্য Counter/User-এর Temporary Hold-এ আছে', v_seat;
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.tickets tk
      WHERE tk.trip_id = p_trip_id AND tk.seat_number = v_seat AND tk.status = 'sold'
    ) OR EXISTS (
      SELECT 1 FROM public.ticket_reservation_seats rs
      JOIN public.ticket_reservations r ON r.id = rs.reservation_id
      WHERE rs.trip_id = p_trip_id AND rs.seat_number = v_seat
        AND r.status IN ('active','confirmed')
        AND (r.expires_at IS NULL OR r.expires_at > now())
    ) THEN
      RAISE EXCEPTION 'Seat % ইতিমধ্যে বিক্রি বা Reserved', v_seat;
    END IF;
  END LOOP;

  -- Expire old reservations and release every linked inventory row atomically.
  WITH expired_reservations AS (
    UPDATE public.ticket_reservations AS r
    SET status = 'expired',
        updated_at = now()
    WHERE r.trip_id = p_trip_id
      AND r.status = 'active'
      AND r.expires_at IS NOT NULL
      AND r.expires_at <= now()
    RETURNING r.id
  )
  UPDATE public.trip_seats AS ts
  SET reservation_id = NULL
  WHERE ts.reservation_id IN (
    SELECT er.id
    FROM expired_reservations AS er
  );

  INSERT INTO public.ticket_reservations
    (trip_id, counter_id, reserved_by, reservation_type, status, expires_at, created_at, updated_at)
  VALUES
    (p_trip_id, v_counter_id, auth.uid(), p_reservation_type, 'active', v_expiry, now(), now())
  RETURNING id INTO v_reservation_id;

  INSERT INTO public.ticket_reservation_seats
    (reservation_id, trip_id, seat_number, passenger_name, passenger_phone,
     passenger_gender, boarding_stop_id, dropping_stop_id, ticket_price, created_at)
  SELECT v_reservation_id, p_trip_id, btrim(s.seat), btrim(p_passenger_name),
         btrim(p_passenger_phone), p_passenger_gender, p_boarding_stop_id,
         p_dropping_stop_id, v_trip.ticket_price, now()
  FROM unnest(p_seat_numbers) AS s(seat);

  UPDATE public.trip_seats
  SET reservation_id=v_reservation_id,
      status='available',
      hold_until=NULL,
      held_by=NULL,
      held_counter_id=NULL
  WHERE trip_id=p_trip_id AND seat_number IN (
    SELECT btrim(s.seat) FROM unnest(p_seat_numbers) AS s(seat)
  );

  RETURN v_reservation_id;
END;
$function$;

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
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Login required'; END IF;
  v_role := public.busnex_user_role();
  v_company_id := public.busnex_company_id();
  v_counter_id := public.busnex_counter_id();

  SELECT r.* INTO v_res
  FROM public.ticket_reservations r
  JOIN public.trips t ON t.id = r.trip_id
  WHERE r.id = p_reservation_id
    AND (
      v_role = 'super_admin'
      OR (v_role = 'company_manager' AND t.company_id = v_company_id)
      OR (v_role = 'counter_operator' AND r.counter_id = v_counter_id AND t.company_id = v_company_id)
    )
  FOR UPDATE OF r;
  IF NOT FOUND THEN RAISE EXCEPTION 'Reservation পাওয়া যায়নি অথবা অনুমতি নেই'; END IF;
  IF v_res.status <> 'active' THEN RAISE EXCEPTION 'শুধু Active Reservation Confirm করা যাবে'; END IF;
  IF v_res.expires_at IS NOT NULL AND v_res.expires_at <= now() THEN
    UPDATE public.ticket_reservations SET status='expired',updated_at=now() WHERE id=p_reservation_id;
    RAISE EXCEPTION 'Reservation-এর সময় শেষ হয়ে গেছে';
  END IF;

  UPDATE public.ticket_reservations
  SET confirmed_at=COALESCE(confirmed_at,now()), updated_at=now()
  WHERE id=p_reservation_id;
  RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION public.busnex_cancel_reservation(p_reservation_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_role text;
  v_company_id uuid;
  v_counter_id uuid;
  v_status text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Login required'; END IF;
  v_role := public.busnex_user_role();
  v_company_id := public.busnex_company_id();
  v_counter_id := public.busnex_counter_id();

  SELECT r.status INTO v_status
  FROM public.ticket_reservations r
  JOIN public.trips t ON t.id = r.trip_id
  WHERE r.id = p_reservation_id
    AND (
      v_role = 'super_admin'
      OR (v_role = 'company_manager' AND t.company_id = v_company_id)
      OR (v_role = 'counter_operator' AND r.counter_id = v_counter_id AND t.company_id = v_company_id)
    )
  FOR UPDATE OF r;
  IF NOT FOUND THEN RAISE EXCEPTION 'Reservation পাওয়া যায়নি অথবা অনুমতি নেই'; END IF;
  IF v_status <> 'active' THEN RAISE EXCEPTION 'এই Reservation Cancel করা যাবে না'; END IF;

  UPDATE public.ticket_reservations
  SET status='cancelled', updated_at=now()
  WHERE id=p_reservation_id;
  UPDATE public.trip_seats
  SET reservation_id=NULL
  WHERE reservation_id=p_reservation_id;
  RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION public.busnex_set_vip_reservation_expiry(
  p_reservation_id uuid,
  p_expires_at timestamptz
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_role text;
  v_company_id uuid;
  v_type text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Login required'; END IF;
  v_role := public.busnex_user_role();
  v_company_id := public.busnex_company_id();
  IF v_role IS DISTINCT FROM 'super_admin' AND v_role IS DISTINCT FROM 'company_manager' THEN
    RAISE EXCEPTION 'Only Manager or Super Admin can set VIP expiry';
  END IF;
  IF p_expires_at IS NOT NULL AND p_expires_at <= now() THEN
    RAISE EXCEPTION 'Expiry must be in the future or NULL';
  END IF;

  SELECT r.reservation_type INTO v_type
  FROM public.ticket_reservations r
  JOIN public.trips t ON t.id=r.trip_id
  WHERE r.id=p_reservation_id
    AND (v_role='super_admin' OR t.company_id=v_company_id)
  FOR UPDATE OF r;
  IF NOT FOUND OR v_type <> 'vip' THEN
    RAISE EXCEPTION 'VIP Reservation পাওয়া যায়নি অথবা অনুমতি নেই';
  END IF;

  UPDATE public.ticket_reservations
  SET expires_at=p_expires_at, updated_at=now()
  WHERE id=p_reservation_id AND status='active' AND confirmed_at IS NULL;
  RETURN FOUND;
END;
$function$;


CREATE OR REPLACE FUNCTION public.busnex_expire_reservations()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_role text;
  v_company_id uuid;
  v_expired integer;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Login required'; END IF;
  v_role := public.busnex_user_role();
  v_company_id := public.busnex_company_id();
  IF v_role IS DISTINCT FROM 'super_admin'
     AND v_role IS DISTINCT FROM 'company_manager'
     AND v_role IS DISTINCT FROM 'counter_operator' THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  WITH expired AS (
    UPDATE public.ticket_reservations r
    SET status='expired', updated_at=now()
    FROM public.trips t
    WHERE t.id=r.trip_id
      AND r.status='active'
      AND r.expires_at IS NOT NULL
      AND r.expires_at<=now()
      AND (v_role='super_admin' OR t.company_id=v_company_id)
    RETURNING r.id
  ),
  cleared AS (
    UPDATE public.trip_seats ts
    SET reservation_id=NULL
    WHERE ts.reservation_id IN (SELECT id FROM expired)
    RETURNING ts.id
  )
  SELECT count(*)::integer INTO v_expired FROM expired;
  RETURN v_expired;
END;
$function$;

REVOKE ALL ON FUNCTION public.busnex_expire_reservations() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_expire_reservations() TO authenticated;

REVOKE ALL ON FUNCTION public.busnex_create_reservation(uuid,text,text[],text,text,text,uuid,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_create_reservation(uuid,text,text[],text,text,text,uuid,uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.busnex_confirm_reservation(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_confirm_reservation(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.busnex_cancel_reservation(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_cancel_reservation(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.busnex_set_vip_reservation_expiry(uuid,timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_set_vip_reservation_expiry(uuid,timestamptz) TO authenticated;

-- ===== 20261113000800_billing_due_dashboard_notice.sql =====
-- Allow company managers and counter operators to see their company's outstanding invoice summary.
CREATE OR REPLACE FUNCTION public.busnex_get_company_billing_due()
RETURNS TABLE(total_due numeric, invoice_count bigint, earliest_due date)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_role text;
  v_company_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Login required'; END IF;
  v_role := public.busnex_user_role();
  v_company_id := public.busnex_company_id();
  IF v_role IS DISTINCT FROM 'company_manager' AND v_role IS DISTINCT FROM 'counter_operator' OR v_company_id IS NULL THEN
    RAISE EXCEPTION 'Company billing summary is not available for this account';
  END IF;

  RETURN QUERY
  SELECT COALESCE(sum(GREATEST(i.amount-i.paid_amount,0)),0)::numeric,
         count(*) FILTER (WHERE i.amount > i.paid_amount),
         min(i.due_date) FILTER (WHERE i.amount > i.paid_amount)
  FROM public.company_billing_invoices i
  WHERE i.company_id=v_company_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.busnex_get_company_billing_due() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_get_company_billing_due() TO authenticated;


-- ===== 20261114000100_fix_confirm_reservation_expiry_cleanup.sql =====
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


COMMIT;
