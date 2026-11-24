ALTER TABLE public.busnex_site_settings
  ADD COLUMN IF NOT EXISTS ticket_footer_text varchar(180)
  NOT NULL DEFAULT 'BUSNEX থেকে টিকিট কাটুন ঘরে বসেই';
