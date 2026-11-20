-- BUSNEX: per-seat counter-operator discounts.
-- Keep ticket_price as the original trip fare; store the discount and actual paid fare separately.
ALTER TABLE public.tickets
  ADD COLUMN IF NOT EXISTS discount_amount numeric(12,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS paid_price numeric(12,2);

UPDATE public.tickets
SET paid_price = ticket_price
WHERE paid_price IS NULL;

ALTER TABLE public.tickets
  ALTER COLUMN paid_price SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'tickets_discount_amount_nonnegative'
      AND conrelid = 'public.tickets'::regclass
  ) THEN
    ALTER TABLE public.tickets
      ADD CONSTRAINT tickets_discount_amount_nonnegative
      CHECK (discount_amount >= 0 AND discount_amount <= ticket_price);
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'tickets_paid_price_matches_discount'
      AND conrelid = 'public.tickets'::regclass
  ) THEN
    ALTER TABLE public.tickets
      ADD CONSTRAINT tickets_paid_price_matches_discount
      CHECK (paid_price = ticket_price - discount_amount);
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.busnex_sell_ticket_with_discount(
  p_trip_id uuid,
  p_seat_number text,
  p_passenger_name text,
  p_passenger_phone text,
  p_boarding_stop_id uuid,
  p_dropping_stop_id uuid,
  p_passenger_gender text,
  p_confirm_past_date boolean,
  p_discount_amount numeric DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_ticket record;
  v_discount numeric(12,2) := COALESCE(p_discount_amount, 0);
  v_fare numeric(12,2);
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'অনুগ্রহ করে লগইন করুন';
  END IF;
  IF v_discount < 0 OR v_discount <> round(v_discount, 2) THEN
    RAISE EXCEPTION 'Discount শূন্য বা ধনাত্মক হতে হবে এবং সর্বোচ্চ ২ দশমিক ঘর হতে পারবে';
  END IF;
  IF public.busnex_user_role() <> 'counter_operator' AND v_discount <> 0 THEN
    RAISE EXCEPTION 'শুধু Counter Operator Discount দিতে পারবেন';
  END IF;

  SELECT * INTO v_ticket
  FROM public.busnex_sell_ticket(
    p_trip_id, p_seat_number, p_passenger_name, p_passenger_phone,
    p_boarding_stop_id, p_dropping_stop_id, p_passenger_gender,
    COALESCE(p_confirm_past_date, false)
  );

  v_fare := v_ticket.ticket_price;
  IF v_discount > v_fare THEN
    RAISE EXCEPTION 'Discount মূল Fare-এর বেশি হতে পারবে না';
  END IF;

  UPDATE public.tickets
  SET discount_amount = v_discount,
      paid_price = v_fare - v_discount
  WHERE id = v_ticket.ticket_id
    AND trip_id = p_trip_id
    AND seat_number = btrim(p_seat_number)
    AND status = 'sold';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Ticket Discount সংরক্ষণ করা যায়নি';
  END IF;

  RETURN jsonb_build_object(
    'ticket_id', v_ticket.ticket_id,
    'trip_id', v_ticket.trip_id,
    'seat_number', v_ticket.seat_number,
    'passenger_name', v_ticket.passenger_name,
    'ticket_price', v_fare,
    'discount_amount', v_discount,
    'paid_price', v_fare - v_discount,
    'status', v_ticket.status
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.busnex_sell_tickets_batch_with_discount(
  p_trip_id uuid,
  p_seat_numbers text[],
  p_discount_amounts numeric[],
  p_passenger_name text,
  p_passenger_phone text,
  p_boarding_stop_id uuid,
  p_dropping_stop_id uuid,
  p_passenger_gender text,
  p_confirm_past_date boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_seat text;
  v_index integer := 0;
  v_result jsonb := '[]'::jsonb;
  v_ticket jsonb;
  v_count integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Login required';
  END IF;
  IF p_seat_numbers IS NULL THEN
    RAISE EXCEPTION 'কমপক্ষে একটি Seat নির্বাচন করুন';
  END IF;
  v_count := cardinality(p_seat_numbers);
  IF v_count < 1 OR v_count > 8 THEN
    RAISE EXCEPTION 'একসঙ্গে সর্বোচ্চ ৮টি Seat বিক্রি করা যাবে';
  END IF;
  IF p_discount_amounts IS NULL OR cardinality(p_discount_amounts) <> v_count THEN
    RAISE EXCEPTION 'প্রতিটি Seat-এর জন্য Discount দিতে হবে';
  END IF;
  IF EXISTS (
    SELECT 1 FROM unnest(p_seat_numbers) AS x(seat_number)
    WHERE x.seat_number IS NULL OR btrim(x.seat_number) = ''
  ) THEN
    RAISE EXCEPTION 'Invalid seat number';
  END IF;
  IF (SELECT count(DISTINCT btrim(x.seat_number))
      FROM unnest(p_seat_numbers) AS x(seat_number)) <> v_count THEN
    RAISE EXCEPTION 'একই Seat একাধিকবার নির্বাচন করা হয়েছে';
  END IF;

  FOR v_seat IN
    SELECT btrim(x.seat_number)
    FROM unnest(p_seat_numbers) AS x(seat_number)
    ORDER BY btrim(x.seat_number)
  LOOP
    v_index := v_index + 1;
    v_ticket := public.busnex_sell_ticket_with_discount(
      p_trip_id, v_seat, p_passenger_name, p_passenger_phone,
      p_boarding_stop_id, p_dropping_stop_id, p_passenger_gender,
      COALESCE(p_confirm_past_date, false), p_discount_amounts[v_index]
    );
    v_result := v_result || jsonb_build_array(
      jsonb_build_object('seat_number', v_seat, 'result', v_ticket)
    );
  END LOOP;
  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.busnex_sell_ticket_with_discount(uuid,text,text,text,uuid,uuid,text,boolean,numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_sell_ticket_with_discount(uuid,text,text,text,uuid,uuid,text,boolean,numeric) TO authenticated;
REVOKE ALL ON FUNCTION public.busnex_sell_tickets_batch_with_discount(uuid,text[],numeric[],text,text,uuid,uuid,text,boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.busnex_sell_tickets_batch_with_discount(uuid,text[],numeric[],text,text,uuid,uuid,text,boolean) TO authenticated;

NOTIFY pgrst, 'reload schema';
