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
