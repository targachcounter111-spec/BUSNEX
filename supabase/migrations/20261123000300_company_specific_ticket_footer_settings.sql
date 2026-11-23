CREATE TABLE IF NOT EXISTS public.company_ticket_settings (
  company_id uuid PRIMARY KEY REFERENCES public.companies(id) ON DELETE CASCADE,
  footer_text varchar(180) NOT NULL DEFAULT 'BUSNEX থেকে টিকিট কাটুন ঘরে বসেই',
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid REFERENCES auth.users(id)
);
ALTER TABLE public.company_ticket_settings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS company_ticket_settings_authenticated_read ON public.company_ticket_settings;
CREATE POLICY company_ticket_settings_authenticated_read
ON public.company_ticket_settings FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS company_ticket_settings_super_admin_insert ON public.company_ticket_settings;
CREATE POLICY company_ticket_settings_super_admin_insert
ON public.company_ticket_settings FOR INSERT TO authenticated
WITH CHECK (public.busnex_user_role() = 'super_admin');
DROP POLICY IF EXISTS company_ticket_settings_super_admin_update ON public.company_ticket_settings;
CREATE POLICY company_ticket_settings_super_admin_update
ON public.company_ticket_settings FOR UPDATE TO authenticated
USING (public.busnex_user_role() = 'super_admin')
WITH CHECK (public.busnex_user_role() = 'super_admin');
DROP POLICY IF EXISTS company_ticket_settings_super_admin_delete ON public.company_ticket_settings;
CREATE POLICY company_ticket_settings_super_admin_delete
ON public.company_ticket_settings FOR DELETE TO authenticated
USING (public.busnex_user_role() = 'super_admin');
