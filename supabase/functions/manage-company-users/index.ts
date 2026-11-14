import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const allowedOrigins = new Set([
  "https://busnex.vercel.app",
  "https://busnex-git-busnex-redesign-busnex.vercel.app",
]);

const corsHeaders = (origin: string | null) => ({
  "Access-Control-Allow-Origin": origin && allowedOrigins.has(origin)
    ? origin
    : "https://busnex.vercel.app",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
  "Content-Type": "application/json",
  "Cache-Control": "no-store",
});

const json = (status: number, body: Record<string, unknown>, origin: string | null) =>
  new Response(JSON.stringify(body), { status, headers: corsHeaders(origin) });

const normalizeLoginId = (value: unknown) =>
  typeof value === "string" ? value.trim().toUpperCase() : "";

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("Origin");
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders(origin) });
  if (req.method !== "POST") return json(405, { success: false, message: "শুধু POST request গ্রহণযোগ্য।" }, origin);
  if (origin && !allowedOrigins.has(origin)) return json(403, { success: false, message: "Origin অনুমোদিত নয়।" }, origin);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SECRET_KEYS") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) {
    return json(500, { success: false, message: "Backend environment configuration অসম্পূর্ণ।" }, origin);
  }

  const authorization = req.headers.get("Authorization") ?? "";
  const tokenMatch = authorization.match(/^Bearer\s+(.+)$/i);
  if (!tokenMatch) return json(401, { success: false, message: "Login session পাওয়া যায়নি।" }, origin);

  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: authData, error: authError } = await admin.auth.getUser(tokenMatch[1]);
  if (authError || !authData.user) return json(401, { success: false, message: "Login session সঠিক নয়।" }, origin);

  const { data: caller, error: callerError } = await admin
    .from("profiles")
    .select("id, role, company_id, counter_id, is_active")
    .eq("id", authData.user.id)
    .maybeSingle();

  if (callerError || !caller || caller.is_active === false) {
    return json(403, { success: false, message: "আপনার এই কাজের অনুমতি নেই।" }, origin);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json(400, { success: false, message: "Request data সঠিক JSON নয়।" }, origin);
  }

  const action = body.action;
  const loginId = normalizeLoginId(body.login_id);

  if (action === "set_operator_active") {
    if (caller.role !== "super_admin" && caller.role !== "company_manager") {
      return json(403, { success: false, message: "শুধু Super Admin বা Manager Operator status পরিবর্তন করতে পারবেন।" }, origin);
    }

    const targetId = typeof body.profile_id === "string" ? body.profile_id : "";
    const active = body.is_active;
    if (!targetId || typeof active !== "boolean") {
      return json(400, { success: false, message: "Operator ID এবং Active status দিতে হবে।" }, origin);
    }

    let targetQuery = admin
      .from("profiles")
      .select("id, company_id, role")
      .eq("id", targetId)
      .eq("role", "counter_operator");
    if (caller.role === "company_manager") targetQuery = targetQuery.eq("company_id", caller.company_id);
    const { data: target, error: targetError } = await targetQuery.maybeSingle();

    if (targetError || !target) return json(404, { success: false, message: "এই Operator ID পাওয়া যায়নি বা আপনার Company-র নয়।" }, origin);

    const { error: updateError } = await admin
      .from("profiles")
      .update({ is_active: active })
      .eq("id", target.id)
      .eq("role", "counter_operator");

    if (updateError) return json(400, { success: false, message: updateError.message }, origin);
    return json(200, { success: true, message: active ? "Operator ID Active করা হয়েছে।" : "Operator ID Deactivate করা হয়েছে।" }, origin);
  }

  if (action !== "create_manager" && action !== "create_operator") {
    return json(400, { success: false, message: "Action সঠিক নয়।" }, origin);
  }

  if (!loginId || !/^[A-Z0-9._-]{4,40}$/.test(loginId)) {
    return json(400, { success: false, message: "Login ID ৪–৪০ অক্ষরের হতে হবে; শুধু ইংরেজি অক্ষর, সংখ্যা, dot, underscore বা hyphen ব্যবহার করুন।" }, origin);
  }

  const password = typeof body.password === "string" ? body.password : "";
  const fullName = typeof body.full_name === "string" ? body.full_name.trim() : "";
  const companyId = typeof body.company_id === "string" ? body.company_id : "";

  if (password.length < 8 || !fullName || !companyId) {
    return json(400, { success: false, message: "নাম, Company এবং কমপক্ষে ৮ অক্ষরের Password দিতে হবে।" }, origin);
  }

  if (caller.role !== "super_admin" && caller.role !== "company_manager") {
    return json(403, { success: false, message: "আপনার নতুন Login ID তৈরির অনুমতি নেই।" }, origin);
  }

  if (caller.role === "company_manager" && caller.company_id !== companyId) {
    return json(403, { success: false, message: "Manager শুধু নিজের Company-র জন্য ID তৈরি করতে পারবেন।" }, origin);
  }

  const { data: company, error: companyError } = await admin
    .from("companies")
    .select("id")
    .eq("id", companyId)
    .maybeSingle();

  if (companyError || !company) return json(404, { success: false, message: "Company পাওয়া যায়নি।" }, origin);

  let role: "company_manager" | "counter_operator";
  let counterId: string | null = null;
  let region: string | null = null;
  let idType: string | null = null;

  if (action === "create_manager") {
    if (caller.role !== "super_admin") {
      return json(403, { success: false, message: "শুধু Super Admin Manager ID তৈরি করতে পারবেন।" }, origin);
    }
    role = "company_manager";
  } else {
    role = "counter_operator";
    counterId = typeof body.counter_id === "string" ? body.counter_id : null;
    region = typeof body.region === "string" ? body.region.toUpperCase() : "ALL";
    idType = typeof body.id_type === "string" ? body.id_type.toUpperCase() : "OPERATOR";

    if (!counterId) return json(400, { success: false, message: "Counter নির্বাচন করুন।" }, origin);
    if (!["NB", "SB", "DHAKA", "ALL"].includes(region)) return json(400, { success: false, message: "Region সঠিক নয়।" }, origin);
    if (!["OPERATOR", "AGENT"].includes(idType)) return json(400, { success: false, message: "ID Type সঠিক নয়।" }, origin);

    const { data: counter, error: counterError } = await admin
      .from("counters")
      .select("id, company_id, is_active")
      .eq("id", counterId)
      .maybeSingle();

    if (counterError || !counter || counter.company_id !== companyId || counter.is_active === false) {
      return json(400, { success: false, message: "নির্বাচিত Counter এই Company-র Active Counter নয়।" }, origin);
    }
  }

  const syntheticEmail = `${loginId.toLowerCase()}@busnex.invalid`;
  const { data: createdAuth, error: createAuthError } = await admin.auth.admin.createUser({
    email: syntheticEmail,
    password,
    email_confirm: true,
    user_metadata: { busnex_login_id: loginId },
  });

  if (createAuthError || !createdAuth.user) {
    return json(400, { success: false, message: createAuthError?.message ?? "Auth user তৈরি করা যায়নি।" }, origin);
  }

  const profileRow = {
    id: createdAuth.user.id,
    company_id: companyId,
    counter_id: counterId,
    full_name: fullName,
    role,
    login_id: loginId,
    region,
    id_type: idType,
    is_active: true,
  };

  const { error: profileError } = await admin.from("profiles").insert(profileRow);
  if (profileError) {
    await admin.auth.admin.deleteUser(createdAuth.user.id);
    return json(400, {
      success: false,
      message: profileError.code === "23505"
        ? "এই Login ID অথবা Counter-এ Active Operator আগে থেকেই আছে।"
        : profileError.message,
    }, origin);
  }

  return json(200, {
    success: true,
    message: role === "company_manager" ? "Manager Login ID তৈরি হয়েছে।" : "Counter Operator Login ID তৈরি হয়েছে।",
    profile: {
      id: createdAuth.user.id,
      login_id: loginId,
      full_name: fullName,
      role,
      company_id: companyId,
      counter_id: counterId,
      region,
      id_type: idType,
      is_active: true,
    },
  }, origin);
});
