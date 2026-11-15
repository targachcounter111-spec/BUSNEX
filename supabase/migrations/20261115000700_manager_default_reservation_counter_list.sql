-- Securely list active counters for Manager/Super Admin reservation booking.
-- Managers see only their own company's counters; Super Admin must choose a company.
CREATE OR REPLACE FUNCTION public.busnex_get_reservation_booking_counters(p_company_id uuid)
RETURNS TABLE(counter_id uuid, counter_name text, counter_address text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_role text;
  v_company_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Login required';
  END IF;

  v_role := public.busnex_user_role();
  v_company_id := public.busnex_company_id();

  IF v_role = 'company_manager' THEN
    IF v_company_id IS NULL OR (p_company_id IS NOT NULL AND p_company_id <> v_company_id) THEN
      RAISE EXCEPTION 'অন্য Company-এর Counter দেখা যাবে না';
    END IF;
  ELSIF v_role = 'super_admin' THEN
    IF p_company_id IS NULL THEN
      RAISE EXCEPTION 'Company নির্বাচন করুন';
    END IF;
    v_company_id := p_company_id;
  ELSE
    RAISE EXCEPTION 'Not authorized';
  END IF;

  RETURN QUERY
    SELECT c.id, c.name, c.address
    FROM public.counters c
    WHERE c.company_id = v_company_id
      AND c.is_active = true
    ORDER BY c.name;
END;
$function$;

REVOKE ALL ON FUNCTION public.busnex_get_reservation_booking_counters(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_get_reservation_booking_counters(uuid) TO authenticated;
