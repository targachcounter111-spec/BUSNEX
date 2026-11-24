-- BUSNEX: configurable per-company sold-seat service pricing.
-- Existing ledger rows remain immutable at their original 0.50 BDT rate.
-- New sold tickets snapshot the company's active rate exactly once.

BEGIN;

CREATE TABLE IF NOT EXISTS public.company_billing_rates (
  company_id uuid PRIMARY KEY REFERENCES public.companies(id) ON DELETE RESTRICT,
  rate_per_seat numeric(12,2) NOT NULL DEFAULT 0.50
    CHECK (rate_per_seat >= 0 AND rate_per_seat = round(rate_per_seat, 2)),
  updated_by uuid REFERENCES auth.users(id),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Existing companies keep the current 0.50 BDT default unless Admin changes it.
INSERT INTO public.company_billing_rates (company_id, rate_per_seat)
SELECT c.id, 0.50
FROM public.companies c
ON CONFLICT (company_id) DO NOTHING;

ALTER TABLE public.company_billing_rates ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.company_billing_rates FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.company_billing_rates TO authenticated;

DROP POLICY IF EXISTS busnex_company_billing_rates_select
  ON public.company_billing_rates;
CREATE POLICY busnex_company_billing_rates_select
ON public.company_billing_rates
FOR SELECT TO authenticated
USING (public.busnex_user_role() = 'super_admin');

-- Remove the old fixed-0.50 constraints. The stored rate/fee for each
-- historical ledger row is never rewritten by this migration.
ALTER TABLE public.company_billing_ledger
  DROP CONSTRAINT IF EXISTS company_billing_ledger_rate_check,
  DROP CONSTRAINT IF EXISTS company_billing_ledger_fee_amount_check;

ALTER TABLE public.company_billing_ledger
  ADD CONSTRAINT company_billing_ledger_rate_nonnegative
    CHECK (rate >= 0 AND rate = round(rate, 2)),
  ADD CONSTRAINT company_billing_ledger_fee_matches_rate
    CHECK (fee_amount = rate AND fee_amount >= 0);

CREATE OR REPLACE FUNCTION public.busnex_set_company_billing_rate(
  p_company_id uuid,
  p_rate_per_seat numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_rate numeric(12,2);
  v_company_name text;
BEGIN
  IF auth.uid() IS NULL
     OR public.busnex_user_role() IS DISTINCT FROM 'super_admin' THEN
    RAISE EXCEPTION 'শুধুমাত্র Super Admin Company Service Charge পরিবর্তন করতে পারবেন';
  END IF;

  IF p_company_id IS NULL
     OR p_rate_per_seat IS NULL
     OR p_rate_per_seat < 0
     OR p_rate_per_seat <> round(p_rate_per_seat, 2) THEN
    RAISE EXCEPTION 'Rate শূন্য বা তার বেশি হতে হবে এবং সর্বোচ্চ ২ দশমিক ঘর হতে পারবে';
  END IF;

  SELECT c.name INTO v_company_name
  FROM public.companies c
  WHERE c.id = p_company_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Company পাওয়া যায়নি';
  END IF;

  v_rate := p_rate_per_seat::numeric(12,2);

  INSERT INTO public.company_billing_rates
    (company_id, rate_per_seat, updated_by, updated_at)
  VALUES
    (p_company_id, v_rate, auth.uid(), now())
  ON CONFLICT (company_id)
  DO UPDATE SET
    rate_per_seat = EXCLUDED.rate_per_seat,
    updated_by = EXCLUDED.updated_by,
    updated_at = now();

  RETURN jsonb_build_object(
    'success', true,
    'company_id', p_company_id,
    'company_name', v_company_name,
    'rate_per_seat', v_rate
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.busnex_record_sold_ticket_fee()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_company_id uuid;
  v_rate numeric(12,2);
BEGIN
  IF NEW.status IS DISTINCT FROM 'sold' THEN
    RETURN NEW;
  END IF;

  SELECT t.company_id INTO v_company_id
  FROM public.trips t
  WHERE t.id = NEW.trip_id;

  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'Sold Ticket-এর Company পাওয়া যায়নি; Billing Fee সংরক্ষণ করা যায়নি';
  END IF;

  SELECT COALESCE(
    (SELECT r.rate_per_seat
     FROM public.company_billing_rates r
     WHERE r.company_id = v_company_id),
    0.50
  ) INTO v_rate;

  INSERT INTO public.company_billing_ledger
    (ticket_id, trip_id, company_id, seat_number, rate, fee_amount, sold_at)
  VALUES
    (NEW.id, NEW.trip_id, v_company_id, NEW.seat_number, v_rate, v_rate,
     COALESCE(NEW.created_at, now()))
  ON CONFLICT (ticket_id) DO NOTHING;

  RETURN NEW;
END;
$function$;

-- Keep monthly invoices synchronized with the actual immutable per-ticket
-- fee ledger. rate_per_seat is the effective average if rates changed mid-month.
CREATE OR REPLACE FUNCTION public.busnex_sync_monthly_invoice_from_ledger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_period_start date;
  v_period_end date;
  v_due_date date;
  v_count integer;
  v_amount numeric(12,2);
  v_rate numeric(12,2);
  v_invoice_id uuid;
BEGIN
  v_period_start := date_trunc(
    'month',
    NEW.sold_at AT TIME ZONE 'Asia/Dhaka'
  )::date;
  v_period_end := (v_period_start + interval '1 month')::date;
  v_due_date := (v_period_start + interval '1 month' + interval '6 days')::date;

  SELECT count(*)::integer, COALESCE(sum(l.fee_amount), 0)::numeric(12,2)
    INTO v_count, v_amount
  FROM public.company_billing_ledger l
  WHERE l.company_id = NEW.company_id
    AND l.sold_at >= (v_period_start::timestamp AT TIME ZONE 'Asia/Dhaka')
    AND l.sold_at < (v_period_end::timestamp AT TIME ZONE 'Asia/Dhaka');

  SELECT COALESCE(
    (SELECT r.rate_per_seat
     FROM public.company_billing_rates r
     WHERE r.company_id = NEW.company_id),
    0.50
  ) INTO v_rate;

  INSERT INTO public.company_billing_invoices
    (company_id, period_start, period_end, due_date, sold_seat_count,
     rate_per_seat, amount, paid_amount, status, created_by, created_at, updated_at)
  VALUES
    (NEW.company_id, v_period_start, v_period_end, v_due_date, v_count,
     CASE WHEN v_count > 0 THEN round(v_amount / v_count, 2) ELSE v_rate END,
     v_amount, 0, CASE WHEN v_amount = 0 THEN 'paid' ELSE 'due' END,
     NULL, now(), now())
  ON CONFLICT (company_id, period_start, period_end)
  DO UPDATE SET
    due_date = EXCLUDED.due_date,
    sold_seat_count = EXCLUDED.sold_seat_count,
    rate_per_seat = EXCLUDED.rate_per_seat,
    amount = GREATEST(EXCLUDED.amount, public.company_billing_invoices.paid_amount),
    status = CASE
      WHEN GREATEST(EXCLUDED.amount, public.company_billing_invoices.paid_amount)
           = public.company_billing_invoices.paid_amount THEN 'paid'
      WHEN public.company_billing_invoices.paid_amount > 0 THEN 'partial'
      ELSE 'due'
    END,
    updated_at = now()
  RETURNING id INTO v_invoice_id;

  IF v_invoice_id IS NULL THEN
    RAISE EXCEPTION 'Automatic Billing Invoice সংরক্ষণ করা যায়নি';
  END IF;

  RETURN NEW;
END;
$function$;

-- Manual invoice refresh also uses the permanent ledger and the effective
-- average rate, not a hard-coded 0.50.
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
  v_rate numeric(12,2);
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

  SELECT count(*)::integer, COALESCE(sum(l.fee_amount),0)::numeric(12,2)
    INTO v_count, v_amount
  FROM public.company_billing_ledger l
  WHERE l.company_id = p_company_id
    AND l.sold_at >= (p_period_start::timestamp AT TIME ZONE 'Asia/Dhaka')
    AND l.sold_at < (p_period_end::timestamp AT TIME ZONE 'Asia/Dhaka');

  SELECT COALESCE(
    (SELECT r.rate_per_seat
     FROM public.company_billing_rates r
     WHERE r.company_id = p_company_id),
    0.50
  ) INTO v_rate;

  INSERT INTO public.company_billing_invoices
    (company_id, period_start, period_end, due_date, sold_seat_count,
     rate_per_seat, amount, paid_amount, status, created_by, created_at, updated_at)
  VALUES
    (p_company_id, p_period_start, p_period_end, p_due_date, v_count,
     CASE WHEN v_count > 0 THEN round(v_amount / v_count, 2) ELSE v_rate END,
     v_amount, 0, CASE WHEN v_amount = 0 THEN 'paid' ELSE 'due' END,
     auth.uid(), now(), now())
  ON CONFLICT (company_id, period_start, period_end)
  DO UPDATE SET
    due_date = EXCLUDED.due_date,
    sold_seat_count = EXCLUDED.sold_seat_count,
    rate_per_seat = EXCLUDED.rate_per_seat,
    amount = GREATEST(EXCLUDED.amount, public.company_billing_invoices.paid_amount),
    status = CASE
      WHEN GREATEST(EXCLUDED.amount, public.company_billing_invoices.paid_amount)
           = public.company_billing_invoices.paid_amount THEN 'paid'
      WHEN public.company_billing_invoices.paid_amount > 0 THEN 'partial'
      ELSE 'due'
    END,
    updated_at = now()
  RETURNING id INTO v_invoice_id;

  IF v_invoice_id IS NULL THEN
    RAISE EXCEPTION 'Invoice সংরক্ষণ করা যায়নি';
  END IF;

  RETURN v_invoice_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.busnex_set_company_billing_rate(uuid,numeric)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_set_company_billing_rate(uuid,numeric)
  TO authenticated;

REVOKE ALL ON FUNCTION public.busnex_record_sold_ticket_fee()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.busnex_sync_monthly_invoice_from_ledger()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.busnex_generate_company_invoice(uuid,date,date,date)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_generate_company_invoice(uuid,date,date,date)
  TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
