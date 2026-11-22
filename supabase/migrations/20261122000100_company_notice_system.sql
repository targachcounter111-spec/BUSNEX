-- BUSNEX Company Notice System
-- Scoped notices: company managers manage only their own company;
-- super admins manage notices for any selected company; operators can read active notices.
BEGIN;

CREATE TABLE IF NOT EXISTS public.company_notices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  title text NOT NULL CHECK (length(btrim(title)) BETWEEN 1 AND 140),
  message text NOT NULL CHECK (length(btrim(message)) BETWEEN 1 AND 1200),
  priority text NOT NULL DEFAULT 'normal'
    CHECK (priority IN ('normal', 'important', 'urgent')),
  starts_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz,
  is_active boolean NOT NULL DEFAULT true,
  created_by uuid NOT NULL DEFAULT auth.uid(),
  updated_by uuid DEFAULT auth.uid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT company_notices_valid_window
    CHECK (expires_at IS NULL OR expires_at > starts_at)
);

CREATE INDEX IF NOT EXISTS company_notices_company_active_window_idx
  ON public.company_notices (company_id, is_active, starts_at, expires_at);

ALTER TABLE public.company_notices ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS company_notices_read_company ON public.company_notices;
CREATE POLICY company_notices_read_company
ON public.company_notices
FOR SELECT TO authenticated
USING (
  (
    public.busnex_user_role() = 'super_admin'
  )
  OR
  (
    company_id = public.busnex_company_id()
    AND (
      public.busnex_user_role() = 'company_manager'
      OR (
        public.busnex_user_role() = 'counter_operator'
        AND is_active IS TRUE
        AND starts_at <= now()
        AND (expires_at IS NULL OR expires_at > now())
      )
    )
  )
);

DROP POLICY IF EXISTS company_notices_insert_manager_admin ON public.company_notices;
CREATE POLICY company_notices_insert_manager_admin
ON public.company_notices
FOR INSERT TO authenticated
WITH CHECK (
  created_by = auth.uid()
  AND (
    public.busnex_user_role() = 'super_admin'
    OR (
      public.busnex_user_role() = 'company_manager'
      AND company_id = public.busnex_company_id()
    )
  )
);

DROP POLICY IF EXISTS company_notices_update_manager_admin ON public.company_notices;
CREATE POLICY company_notices_update_manager_admin
ON public.company_notices
FOR UPDATE TO authenticated
USING (
  public.busnex_user_role() = 'super_admin'
  OR (
    public.busnex_user_role() = 'company_manager'
    AND company_id = public.busnex_company_id()
  )
)
WITH CHECK (
  updated_by = auth.uid()
  AND (
    public.busnex_user_role() = 'super_admin'
    OR (
      public.busnex_user_role() = 'company_manager'
      AND company_id = public.busnex_company_id()
    )
  )
);

DROP POLICY IF EXISTS company_notices_delete_manager_admin ON public.company_notices;
CREATE POLICY company_notices_delete_manager_admin
ON public.company_notices
FOR DELETE TO authenticated
USING (
  public.busnex_user_role() = 'super_admin'
  OR (
    public.busnex_user_role() = 'company_manager'
    AND company_id = public.busnex_company_id()
  )
);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.company_notices TO authenticated;
REVOKE ALL ON public.company_notices FROM anon;

COMMIT;
