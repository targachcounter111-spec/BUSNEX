-- Limit direct API execution of trigger/event-trigger SECURITY DEFINER routines.
REVOKE EXECUTE ON FUNCTION public.busnex_create_trip_stops() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.busnex_queue_ticket_confirmation_sms() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.busnex_sms_snapshot_rate() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.rls_auto_enable() FROM PUBLIC, anon, authenticated;

-- This helper is called by RLS policies, so authenticated users retain execution.
REVOKE EXECUTE ON FUNCTION public.busnex_can_access_trip_region(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_can_access_trip_region(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
