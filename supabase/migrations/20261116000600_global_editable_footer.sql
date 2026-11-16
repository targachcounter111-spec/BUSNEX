-- BUSNEX: globally visible, Super Admin-editable website footer
BEGIN;

CREATE TABLE IF NOT EXISTS public.busnex_site_settings (
  id integer PRIMARY KEY CHECK (id = 1),
  footer_text varchar(180) NOT NULL DEFAULT 'BUSNEX BD CONCERN OF TAFSIR',
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.busnex_site_settings (id, footer_text)
VALUES (1, 'BUSNEX BD CONCERN OF TAFSIR')
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.busnex_site_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS busnex_site_settings_public_read
  ON public.busnex_site_settings;
CREATE POLICY busnex_site_settings_public_read
  ON public.busnex_site_settings
  FOR SELECT
  TO anon, authenticated
  USING (true);

DROP POLICY IF EXISTS busnex_site_settings_super_admin_update
  ON public.busnex_site_settings;
CREATE POLICY busnex_site_settings_super_admin_update
  ON public.busnex_site_settings
  FOR UPDATE
  TO authenticated
  USING (public.busnex_user_role() = 'super_admin')
  WITH CHECK (public.busnex_user_role() = 'super_admin');

GRANT SELECT ON public.busnex_site_settings TO anon, authenticated;
GRANT UPDATE (footer_text, updated_at)
  ON public.busnex_site_settings TO authenticated;

COMMIT;
