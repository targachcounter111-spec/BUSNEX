-- BUSNEX: ensure every ticket insert receives a valid paid_price.
-- Older and newer ticket-sale RPC overloads may omit paid_price.
-- Preserve the fare/discount model: paid_price = ticket_price - discount_amount.
CREATE OR REPLACE FUNCTION public.busnex_set_ticket_paid_price_before_insert()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ''
AS $function$
BEGIN
  NEW.discount_amount := COALESCE(NEW.discount_amount, 0);

  IF NEW.paid_price IS NULL THEN
    NEW.paid_price := NEW.ticket_price - NEW.discount_amount;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS busnex_set_ticket_paid_price_before_insert ON public.tickets;

CREATE TRIGGER busnex_set_ticket_paid_price_before_insert
BEFORE INSERT ON public.tickets
FOR EACH ROW
EXECUTE FUNCTION public.busnex_set_ticket_paid_price_before_insert();

NOTIFY pgrst, 'reload schema';
