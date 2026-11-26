drop function if exists public.busnex_reset_company_billing(uuid);

create function public.busnex_reset_company_billing(p_company_id uuid, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_security public.company_control_security%rowtype;
  v_company_name text;
  v_ledger_count integer := 0;
  v_invoice_count integer := 0;
  v_payment_count integer := 0;
  v_ledger_total numeric(14,2) := 0;
  v_invoice_total numeric(14,2) := 0;
  v_payment_total numeric(14,2) := 0;
  v_ledger_snapshot jsonb := '[]'::jsonb;
  v_invoice_snapshot jsonb := '[]'::jsonb;
  v_payment_snapshot jsonb := '[]'::jsonb;
begin
  if auth.uid() is null or public.busnex_user_role() is distinct from 'super_admin' then
    raise exception 'শুধুমাত্র Super Admin Company Billing Reset করতে পারবেন';
  end if;
  if p_company_id is null then
    raise exception 'একটি Company নির্বাচন করুন';
  end if;

  select * into v_security
  from public.company_control_security
  where id is true
  for update;

  if not found or v_security.pin_hash is null then
    return jsonb_build_object('success', false, 'code', 'PIN_NOT_SET',
      'message', 'আগে My Account থেকে Company Control PIN সেট করুন।');
  end if;

  if v_security.locked_until is not null and v_security.locked_until > now() then
    return jsonb_build_object('success', false, 'code', 'PIN_LOCKED',
      'message', 'অনেকবার ভুল PIN দেওয়া হয়েছে। ১৫ মিনিট পর আবার চেষ্টা করুন।');
  end if;

  if extensions.crypt(coalesce(p_pin, ''), v_security.pin_hash) <> v_security.pin_hash then
    update public.company_control_security
    set failed_attempts = case when failed_attempts + 1 >= 5 then 0 else failed_attempts + 1 end,
        locked_until = case when failed_attempts + 1 >= 5 then now() + interval '15 minutes' else null end,
        updated_at = now()
    where id is true;
    return jsonb_build_object('success', false, 'code', 'INVALID_PIN',
      'message', 'Company Control PIN/Password সঠিক নয়। Billing History Delete করা হয়নি।');
  end if;

  select c.name into v_company_name
  from public.companies c where c.id = p_company_id for update;
  if not found then raise exception 'Company পাওয়া যায়নি'; end if;

  select count(*)::integer, coalesce(sum(l.fee_amount),0)::numeric(14,2),
         coalesce(jsonb_agg(to_jsonb(l)), '[]'::jsonb)
    into v_ledger_count, v_ledger_total, v_ledger_snapshot
  from public.company_billing_ledger l where l.company_id = p_company_id;

  select count(*)::integer, coalesce(sum(i.amount),0)::numeric(14,2),
         coalesce(jsonb_agg(to_jsonb(i)), '[]'::jsonb)
    into v_invoice_count, v_invoice_total, v_invoice_snapshot
  from public.company_billing_invoices i where i.company_id = p_company_id;

  select count(*)::integer, coalesce(sum(p.amount),0)::numeric(14,2),
         coalesce(jsonb_agg(to_jsonb(p)), '[]'::jsonb)
    into v_payment_count, v_payment_total, v_payment_snapshot
  from public.company_billing_payments p
  join public.company_billing_invoices i on i.id = p.invoice_id
  where i.company_id = p_company_id;

  insert into public.company_billing_reset_audit
    (company_id, performed_by, ledger_rows_deleted, invoice_rows_deleted,
     payment_rows_deleted, ledger_fee_total, invoice_amount_total, payment_amount_total,
     ledger_snapshot, invoice_snapshot, payment_snapshot)
  values
    (p_company_id, auth.uid(), v_ledger_count, v_invoice_count,
     v_payment_count, v_ledger_total, v_invoice_total, v_payment_total,
     v_ledger_snapshot, v_invoice_snapshot, v_payment_snapshot);

  delete from public.company_billing_payments p
  using public.company_billing_invoices i
  where p.invoice_id = i.id and i.company_id = p_company_id;
  delete from public.company_billing_invoices where company_id = p_company_id;
  delete from public.company_billing_ledger where company_id = p_company_id;

  update public.company_control_security
  set failed_attempts = 0, locked_until = null, updated_at = now()
  where id is true;

  return jsonb_build_object(
    'success', true, 'company_id', p_company_id, 'company_name', v_company_name,
    'ledger_rows_deleted', v_ledger_count, 'invoice_rows_deleted', v_invoice_count,
    'payment_rows_deleted', v_payment_count, 'ledger_fee_total', v_ledger_total,
    'invoice_amount_total', v_invoice_total, 'payment_amount_total', v_payment_total,
    'message', 'Billing Reset হয়েছে। পুরোনো Billing ও Payment-এর পূর্ণ Snapshot Audit-এ সংরক্ষিত; Ticket, Passenger, Seat, Schedule ও Trip অপরিবর্তিত।'
  );
end;
$function$;

revoke all on function public.busnex_reset_company_billing(uuid, text) from public, anon, authenticated;
grant execute on function public.busnex_reset_company_billing(uuid, text) to authenticated;
