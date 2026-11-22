-- BUSNEX company-specific bill payment reminder
BEGIN;

CREATE TABLE IF NOT EXISTS public.company_bill_reminders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL UNIQUE REFERENCES public.companies(id) ON DELETE CASCADE,
  message text NOT NULL DEFAULT 'আপনার কোম্পানির বকেয়া বিল দ্রুত পরিশোধ করুন।',
  payment_deadline date NOT NULL,
  is_active boolean NOT NULL DEFAULT false,
  created_by uuid NOT NULL DEFAULT auth.uid(),
  updated_by uuid DEFAULT auth.uid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT company_bill_reminders_message_length CHECK (length(btrim(message)) BETWEEN 1 AND 600)
);

ALTER TABLE public.company_bill_reminders ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.company_bill_reminders FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.company_bill_reminders TO authenticated;

DROP POLICY IF EXISTS company_bill_reminders_select_scoped ON public.company_bill_reminders;
CREATE POLICY company_bill_reminders_select_scoped
ON public.company_bill_reminders FOR SELECT TO authenticated
USING (
  public.busnex_user_role() = 'super_admin'
  OR (
    company_id = public.busnex_company_id()
    AND public.busnex_user_role() IN ('company_manager','counter_operator')
    AND is_active IS TRUE
  )
);

DROP POLICY IF EXISTS company_bill_reminders_admin_insert ON public.company_bill_reminders;
CREATE POLICY company_bill_reminders_admin_insert
ON public.company_bill_reminders FOR INSERT TO authenticated
WITH CHECK (
  public.busnex_user_role() = 'super_admin'
  AND created_by = auth.uid()
);

DROP POLICY IF EXISTS company_bill_reminders_admin_update ON public.company_bill_reminders;
CREATE POLICY company_bill_reminders_admin_update
ON public.company_bill_reminders FOR UPDATE TO authenticated
USING (public.busnex_user_role() = 'super_admin')
WITH CHECK (
  public.busnex_user_role() = 'super_admin'
  AND updated_by = auth.uid()
);

DROP POLICY IF EXISTS company_bill_reminders_admin_delete ON public.company_bill_reminders;
CREATE POLICY company_bill_reminders_admin_delete
ON public.company_bill_reminders FOR DELETE TO authenticated
USING (public.busnex_user_role() = 'super_admin');

CREATE OR REPLACE FUNCTION public.busnex_touch_company_bill_reminder()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  NEW.updated_at := now();
  NEW.updated_by := auth.uid();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS company_bill_reminders_touch_updated_at ON public.company_bill_reminders;
CREATE TRIGGER company_bill_reminders_touch_updated_at
BEFORE UPDATE ON public.company_bill_reminders
FOR EACH ROW EXECUTE FUNCTION public.busnex_touch_company_bill_reminder();

COMMIT;
