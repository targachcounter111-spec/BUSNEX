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
