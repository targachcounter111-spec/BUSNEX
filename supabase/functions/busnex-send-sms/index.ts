import { createClient } from "npm:@supabase/supabase-js@2";

const API_URL = "https://bulksmsbd.net/api/smsapi";
const BATCH_SIZE = 10;

function getSecret(name: string): string {
  const raw = Deno.env.get(name) ?? "";
  if (!raw) return "";
  try {
    const parsed = JSON.parse(raw);
    if (typeof parsed === "string") return parsed;
    if (parsed && typeof parsed.default === "string") return parsed.default;
  } catch { /* plain text secret */ }
  return raw;
}

function json(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

function renderMessage(row: Record<string, unknown>): string {
  const replacements: Record<string, string> = {
    company_name: String(row.company_name ?? "BUSNEX"),
    passenger_name: String(row.passenger_name ?? ""),
    seat_number: String(row.seat_number ?? ""),
    journey_at: String(row.journey_at ?? ""),
    date: String(row.journey_at ?? ""),
    time: String(row.journey_at ?? ""),
  };
  let message = String(row.message_template ?? "");
  for (const [key, value] of Object.entries(replacements)) {
    const escaped = key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    message = message.replace(new RegExp(String.raw`\{\{\s*${escaped}\s*\}\}`, "gi"), value);
    message = message.replace(new RegExp(String.raw`\{\s*${escaped}\s*\}`, "gi"), value);
    message = message.replaceAll(`[${key}]`, value);
  }
  return message.trim();
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { success: false, message: "POST required" });

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceKey = getSecret("SUPABASE_SECRET_KEYS") || getSecret("SUPABASE_SERVICE_ROLE_KEY");
  const apiKey = getSecret("BULKSMSBD_API_KEY");
  const senderId = getSecret("BULKSMSBD_SENDER_ID");

  // Only trusted Supabase scheduler/service-role invocations may process the queue.
  const auth = req.headers.get("Authorization") ?? "";
  const token = auth.replace(/^Bearer\s+/i, "").trim();
  if (!serviceKey || !token || token !== serviceKey) {
    return json(401, { success: false, message: "Unauthorized" });
  }
  if (!supabaseUrl || !apiKey || !senderId) {
    console.error("SMS configuration missing", {
      supabaseUrl: Boolean(supabaseUrl), apiKey: Boolean(apiKey), senderId: Boolean(senderId),
    });
    return json(500, {
      success: false,
      message: "SMS configuration incomplete. Set BULKSMSBD_API_KEY and BULKSMSBD_SENDER_ID.",
    });
  }

  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const { data: pending, error: readError } = await admin
    .from("company_sms_outbox")
    .select("id,ticket_id,passenger_phone,passenger_name,company_name,seat_number,journey_at,message_template,attempts")
    .eq("status", "pending")
    .order("created_at", { ascending: true })
    .limit(BATCH_SIZE);

  if (readError) {
    // Return safe PostgREST diagnostics (never credentials or passenger data) so
    // permission/schema errors can be fixed without exposing secrets.
    console.error("SMS queue read failed", {
      code: readError.code,
      message: readError.message,
      details: readError.details,
      hint: readError.hint,
    });
    return json(500, {
      success: false,
      message: "Queue read failed",
      database_error: {
        code: readError.code ?? null,
        message: readError.message,
        details: readError.details ?? null,
        hint: readError.hint ?? null,
      },
    });
  }

  let sent = 0;
  let failed = 0;
  let skipped = 0;

  for (const row of pending ?? []) {
    // Claim each item once. Concurrent workers cannot both claim the same pending row.
    const { data: claimed, error: claimError } = await admin
      .from("company_sms_outbox")
      .update({ status: "sending", attempts: Number(row.attempts ?? 0) + 1, updated_at: new Date().toISOString() })
      .eq("id", row.id)
      .eq("status", "pending")
      .select("id")
      .maybeSingle();

    if (claimError || !claimed) { skipped++; continue; }

    const number = String(row.passenger_phone ?? "").replace(/[^0-9]/g, "").replace(/^\+/, "");
    const message = renderMessage(row);
    if (!/^8801[3-9]\d{8}$/.test(number) || !message) {
      await admin.from("company_sms_outbox")
        .update({ status: "skipped_invalid_number", provider_response: !message ? "Empty SMS message" : "Invalid Bangladesh mobile number" })
        .eq("id", row.id).eq("status", "sending");
      skipped++;
      continue;
    }

    try {
      const params = new URLSearchParams({
        api_key: apiKey,
        type: "text",
        number,
        senderid: senderId,
        message,
      });
      const response = await fetch(API_URL, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8" },
        body: params.toString(),
        signal: AbortSignal.timeout(20000),
      });
      const responseText = (await response.text()).slice(0, 2000);
      const accepted = response.ok && /(^|\b)202(\b|$)/.test(responseText);

      if (accepted) {
        const { error: updateError } = await admin.from("company_sms_outbox")
          .update({
            status: "sent",
            provider_response: responseText,
            provider_message_id: null,
            next_attempt_at: null,
            updated_at: new Date().toISOString(),
          })
          .eq("id", row.id).eq("status", "sending");
        if (updateError) {
          // Do not resend automatically: provider may already have accepted the SMS.
          console.error("Accepted SMS status update failed; manual reconciliation required", row.id, updateError.message);
          failed++;
        } else sent++;
      } else {
        await admin.from("company_sms_outbox")
          .update({
            status: "failed",
            provider_response: responseText || `HTTP ${response.status}`,
            next_attempt_at: null,
            updated_at: new Date().toISOString(),
          })
          .eq("id", row.id).eq("status", "sending");
        failed++;
      }
    } catch (error) {
      // A timeout may happen after provider acceptance. Leave 'sending' for manual review
      // rather than risk sending a duplicate message.
      console.error("SMS provider request uncertain; left in sending state", row.id,
        error instanceof Error ? error.message : "Unknown error");
      failed++;
    }
  }

  return json(200, { success: true, processed: pending?.length ?? 0, sent, failed, skipped });
});
