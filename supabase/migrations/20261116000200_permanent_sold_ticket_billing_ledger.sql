-- BUSNEX: permanent per-sold-ticket billing ledger.
-- A fee is recorded exactly once when a ticket first becomes sold.
-- Ledger rows deliberately have no FK to tickets or trips so later deletion
-- of either record cannot erase an already-earned fee.

BEGIN;

CREATE TABLE IF NOT EXISTS public.company_billing_ledger (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_id uuid NOT NULL UNIQUE,
  trip_id uuid NOT NULL,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  seat_number text NOT NULL,
  rate numeric(12,2) NOT NULL DEFAULT 0.50 CHECK (rate = 0.50),
  fee_amount numeric(12,2) NOT NULL DEFAULT 0.50 CHECK (fee_amount = 0.50),
  sold_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS company_billing_ledger_company_sold_idx
  ON public.company_billing_ledger(company_id, sold_at DESC);
CREATE INDEX IF NOT EXISTS company_billing_ledger_period_idx
  ON public.company_billing_ledger(company_id, sold_at);

ALTER TABLE public.company_billing_ledger ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.company_billing_ledger FROM anon, authenticated;
GRANT SELECT ON public.company_billing_ledger TO authenticated;

DROP POLICY IF EXISTS busnex_billing_ledger_select ON public.company_billing_ledger;
CREATE POLICY busnex_billing_ledger_select
ON public.company_billing_ledger
FOR SELECT TO authenticated
USING (
  public.busnex_user_role() = 'super_admin'
  OR (
    public.busnex_user_role() = 'company_manager'
    AND company_id = public.busnex_company_id()
  )
);

CREATE OR REPLACE FUNCTION public.busnex_record_sold_ticket_fee()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_company_id uuid;
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

  INSERT INTO public.company_billing_ledger
    (ticket_id, trip_id, company_id, seat_number, rate, fee_amount, sold_at)
  VALUES
    (NEW.id, NEW.trip_id, v_company_id, NEW.seat_number, 0.50, 0.50,
     COALESCE(NEW.created_at, now()))
  ON CONFLICT (ticket_id) DO NOTHING;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS busnex_record_sold_ticket_fee ON public.tickets;
CREATE TRIGGER busnex_record_sold_ticket_fee
AFTER INSERT OR UPDATE OF status ON public.tickets
FOR EACH ROW
WHEN (NEW.status = 'sold')
EXECUTE FUNCTION public.busnex_record_sold_ticket_fee();

-- Backfill every currently sold ticket before any future trip/ticket deletion.
INSERT INTO public.company_billing_ledger
  (ticket_id, trip_id, company_id, seat_number, rate, fee_amount, sold_at)
SELECT tk.id, tk.trip_id, tr.company_id, tk.seat_number, 0.50, 0.50,
       COALESCE(tk.created_at, now())
FROM public.tickets tk
JOIN public.trips tr ON tr.id = tk.trip_id
WHERE tk.status = 'sold'
ON CONFLICT (ticket_id) DO NOTHING;

-- Invoice totals now come from the permanent ledger, not live ticket/trip rows.
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

  SELECT count(*)::integer, COALESCE(sum(l.fee_amount),0)::numeric(12,2)
    INTO v_count, v_amount
  FROM public.company_billing_ledger l
  WHERE l.company_id = p_company_id
    AND l.sold_at >= (p_period_start::timestamp AT TIME ZONE 'Asia/Dhaka')
    AND l.sold_at < (p_period_end::timestamp AT TIME ZONE 'Asia/Dhaka');

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
    status = CASE
      WHEN EXCLUDED.amount = public.company_billing_invoices.paid_amount THEN 'paid'
      WHEN public.company_billing_invoices.paid_amount > 0 THEN 'partial'
      ELSE 'due'
    END,
    updated_at = now()
  WHERE public.company_billing_invoices.paid_amount <= EXCLUDED.amount
  RETURNING id INTO v_invoice_id;

  IF v_invoice_id IS NULL THEN
    RAISE EXCEPTION 'Invoice-এর Paid Amount বর্তমান Fee-এর চেয়ে বেশি; হিসাব যাচাই প্রয়োজন';
  END IF;
  RETURN v_invoice_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.busnex_record_sold_ticket_fee() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.busnex_generate_company_invoice(uuid, date, date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_generate_company_invoice(uuid, date, date, date) TO authenticated;

COMMIT;
