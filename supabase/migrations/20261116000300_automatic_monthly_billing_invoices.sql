-- BUSNEX: automatically create/update monthly invoices from permanent fee ledger.
-- Default payment due date: the 7th day of the following month (Bangladesh billing month).
-- Existing payment history is preserved; invoice totals are refreshed from the immutable ledger.

BEGIN;

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

  INSERT INTO public.company_billing_invoices
    (company_id, period_start, period_end, due_date, sold_seat_count,
     rate_per_seat, amount, paid_amount, status, created_by, created_at, updated_at)
  VALUES
    (NEW.company_id, v_period_start, v_period_end, v_due_date, v_count,
     0.50, v_amount, 0,
     CASE WHEN v_amount = 0 THEN 'paid' ELSE 'due' END,
     NULL, now(), now())
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
    RAISE EXCEPTION
      'Automatic Billing stopped: existing paid amount is greater than ledger total for company %, period %',
      NEW.company_id, v_period_start;
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.busnex_sync_monthly_invoice_from_ledger()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS busnex_auto_monthly_invoice_from_ledger
  ON public.company_billing_ledger;

CREATE TRIGGER busnex_auto_monthly_invoice_from_ledger
AFTER INSERT ON public.company_billing_ledger
FOR EACH ROW
EXECUTE FUNCTION public.busnex_sync_monthly_invoice_from_ledger();

-- Create or refresh invoices for all ledger months already recorded.
DO $block$
DECLARE
  r record;
  v_invoice_id uuid;
BEGIN
  FOR r IN
    SELECT
      l.company_id,
      date_trunc('month', l.sold_at AT TIME ZONE 'Asia/Dhaka')::date AS period_start,
      (date_trunc('month', l.sold_at AT TIME ZONE 'Asia/Dhaka')::date + interval '1 month')::date AS period_end,
      (date_trunc('month', l.sold_at AT TIME ZONE 'Asia/Dhaka')::date + interval '1 month' + interval '6 days')::date AS due_date,
      count(*)::integer AS sold_seat_count,
      sum(l.fee_amount)::numeric(12,2) AS amount
    FROM public.company_billing_ledger l
    GROUP BY l.company_id,
      date_trunc('month', l.sold_at AT TIME ZONE 'Asia/Dhaka')::date
    ORDER BY period_start, l.company_id
  LOOP
    INSERT INTO public.company_billing_invoices
      (company_id, period_start, period_end, due_date, sold_seat_count,
       rate_per_seat, amount, paid_amount, status, created_by, created_at, updated_at)
    VALUES
      (r.company_id, r.period_start, r.period_end, r.due_date,
       r.sold_seat_count, 0.50, r.amount, 0,
       CASE WHEN r.amount = 0 THEN 'paid' ELSE 'due' END,
       NULL, now(), now())
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
      RAISE EXCEPTION
        'Automatic Billing migration stopped: existing paid amount is greater than ledger total for company %, period %',
        r.company_id, r.period_start;
    END IF;
  END LOOP;
END;
$block$;

COMMIT;
