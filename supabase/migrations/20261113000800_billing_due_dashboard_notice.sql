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
  IF v_role NOT IN ('company_manager','counter_operator') OR v_company_id IS NULL THEN
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
