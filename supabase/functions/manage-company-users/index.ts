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

function getSecret(primary: string, legacy: string): string {
  const raw = Deno.env.get(primary) ?? Deno.env.get(legacy) ?? "";
  if (!raw) return "";
  try {
    const parsed = JSON.parse(raw);
    if (typeof parsed === "string") return parsed;
    if (parsed && typeof parsed.default === "string") return parsed.default;
    return raw;
  } catch {
    return raw;
  }
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("Origin");
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders(origin) });
  if (req.method !== "POST") return json(405, { success: false, message: "শুধু POST request গ্রহণযোগ্য।" }, origin);
  if (origin && !allowedOrigins.has(origin)) return json(403, { success: false, message: "Origin অনুমোদিত নয়।" }, origin);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = getSecret("SUPABASE_SECRET_KEYS", "SUPABASE_SERVICE_ROLE_KEY");
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

  // During maintenance, only Super Admin may use account-management actions.
  // Fail closed if the maintenance setting cannot be verified.
  if (caller.role !== "super_admin") {
    const { data: maintenanceSettings, error: maintenanceError } = await admin
      .from("busnex_maintenance_settings")
      .select("maintenance_enabled")
      .eq("id", 1)
      .maybeSingle();

    if (maintenanceError || !maintenanceSettings) {
      console.error("manage-company-users maintenance check failed", {
        code: maintenanceError?.code ?? null,
        message: maintenanceError?.message ?? null,
      });
      return json(503, {
        success: false,
        message: "BUSNEX maintenance status যাচাই করা যাচ্ছে না। পরে চেষ্টা করুন।",
      }, origin);
    }

    if (maintenanceSettings.maintenance_enabled === true) {
      return json(503, {
        success: false,
        message: "BUSNEX বর্তমানে Maintenance Mode-এ আছে। Account পরিচালনা সাময়িকভাবে বন্ধ রয়েছে।",
      }, origin);
    }
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json(400, { success: false, message: "Request data সঠিক JSON নয়।" }, origin);
  }

  const action = body.action;

  // Every authenticated user may update their own display name and/or password.
  if (action === "update_own_account") {
    const fullName = typeof body.full_name === "string" ? body.full_name.trim() : "";
    const password = typeof body.password === "string" ? body.password : "";
    if (!fullName && !password) return json(400, { success: false, message: "নতুন নাম অথবা Password দিন।" }, origin);
    if (fullName.length > 120) return json(400, { success: false, message: "নাম ১২০ অক্ষরের মধ্যে হতে হবে।" }, origin);
    if (password && password.length < 8) return json(400, { success: false, message: "Password কমপক্ষে ৮ অক্ষরের হতে হবে।" }, origin);
    if (password) {
      const { error } = await admin.auth.admin.updateUserById(authData.user.id, { password });
      if (error) return json(400, { success: false, message: error.message }, origin);
    }
    if (fullName) {
      const { error } = await admin.from("profiles").update({ full_name: fullName }).eq("id", authData.user.id);
      if (error) return json(400, { success: false, message: error.message }, origin);
    }
    return json(200, { success: true, message: "আপনার Account তথ্য আপডেট হয়েছে।", full_name: fullName || caller.full_name || null }, origin);
  }

  // Super Admin may manage any account; a Company Manager may manage only
  // Operator/Agent accounts belonging to the Manager's own company.
  if (action === "admin_reset_user_credentials") {
    if (caller.role !== "super_admin" && caller.role !== "company_manager") {
      return json(403, { success: false, message: "অন্যের Account পরিবর্তনের অনুমতি নেই।" }, origin);
    }
    const targetId = typeof body.profile_id === "string" ? body.profile_id : "";
    const fullName = typeof body.full_name === "string" ? body.full_name.trim() : "";
    const password = typeof body.password === "string" ? body.password : "";
    if (!targetId || (!fullName && !password)) return json(400, { success: false, message: "Account নির্বাচন করে নতুন নাম অথবা Password দিন।" }, origin);
    if (fullName.length > 120) return json(400, { success: false, message: "নাম ১২০ অক্ষরের মধ্যে হতে হবে।" }, origin);
    if (password && password.length < 8) return json(400, { success: false, message: "নতুন Password কমপক্ষে ৮ অক্ষরের হতে হবে।" }, origin);
    let targetQuery = admin.from("profiles").select("id, role, company_id").eq("id", targetId);
    if (caller.role === "company_manager") {
      targetQuery = targetQuery.eq("company_id", caller.company_id).eq("role", "counter_operator");
    }
    const { data: target, error: targetError } = await targetQuery.maybeSingle();
    if (targetError) return json(500, { success: false, message: targetError.message }, origin);
    if (!target) return json(404, { success: false, message: "এই Account আপনার অনুমোদিত তালিকায় পাওয়া যায়নি।" }, origin);
    if (password) {
      const { error } = await admin.auth.admin.updateUserById(target.id, { password });
      if (error) return json(400, { success: false, message: error.message }, origin);
    }
    if (fullName) {
      const { error } = await admin.from("profiles").update({ full_name: fullName }).eq("id", target.id);
      if (error) return json(400, { success: false, message: error.message }, origin);
    }
    return json(200, { success: true, message: "Account তথ্য আপডেট হয়েছে।" }, origin);
  }

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

  if (action !== "create_manager" && action !== "create_operator" && action !== "create_sub_manager") {
    return json(400, { success: false, message: "Action সঠিক নয়।" }, origin);
  }

  if (!loginId || !/^[A-Z0-9._-]{4,40}$/.test(loginId)) {
    return json(400, { success: false, message: "Login ID ৪–৪০ অক্ষরের হতে হবে; শুধু ইংরেজি অক্ষর, সংখ্যা, dot, underscore বা hyphen ব্যবহার করুন।" }, origin);
  }

  const password = typeof body.password === "string" ? body.password : "";
  const fullName = typeof body.full_name === "string" ? body.full_name.trim() : "";
  // A company_manager must always use the company_id from their authenticated profile.
  // Never trust a company_id supplied by the browser for Manager actions.
  const requestedCompanyId = typeof body.company_id === "string" ? body.company_id.trim() : "";
  const companyId = caller.role === "company_manager"
    ? (typeof caller.company_id === "string" ? caller.company_id : "")
    : requestedCompanyId;

  console.info("manage-company-users create request", {
    action,
    caller_role: caller.role,
    caller_company_id: caller.company_id ?? null,
    requested_company_id: requestedCompanyId || null,
    effective_company_id: companyId || null,
  });

  if (password.length < 8 || !fullName || !companyId) {
    return json(400, { success: false, message: "নাম, Company এবং কমপক্ষে ৮ অক্ষরের Password দিতে হবে।" }, origin);
  }

  if (caller.role !== "super_admin" && caller.role !== "company_manager") {
    return json(403, { success: false, message: "আপনার নতুন Login ID তৈরির অনুমতি নেই।" }, origin);
  }
  if (action === "create_sub_manager" && !["super_admin", "company_manager"].includes(caller.role)) {
    return json(403, { success: false, message: "শুধু Company Manager বা Super Admin Sub Manager ID তৈরি করতে পারবেন।" }, origin);
  }

  if (caller.role === "company_manager" && caller.company_id !== companyId) {
    return json(403, { success: false, message: "Manager শুধু নিজের Company-র জন্য ID তৈরি করতে পারবেন।" }, origin);
  }

  const { data: company, error: companyError } = await admin
    .from("companies")
    .select("id")
    .eq("id", companyId)
    .maybeSingle();

  if (companyError) {
    console.error("manage-company-users company_lookup failed", {
      code: companyError.code ?? null,
      message: companyError.message ?? null,
      details: companyError.details ?? null,
      hint: companyError.hint ?? null,
    });
    return json(500, {
      success: false,
      message: "Company Database Query ব্যর্থ হয়েছে।",
      stage: "company_lookup",
      code: companyError.code ?? "UNKNOWN",
    }, origin);
  }

  if (!company) {
    console.error("manage-company-users company_lookup returned no row", {
      company_id: companyId,
      caller_role: caller.role,
      caller_company_id: caller.company_id ?? null,
    });
    return json(404, {
      success: false,
      message: "Company রেকর্ড পাওয়া যায়নি।",
      stage: "company_not_found",
    }, origin);
  }

  let role: "company_manager" | "counter_operator" | "nb_sub_manager" | "dhaka_sub_manager";
  let counterId: string | null = null;
  let region: string | null = null;
  let idType: string | null = null;
  let defaultBoardingPoint: string | null = null;
  let scheduleRegions: string[] = [];

  if (action === "create_manager") {
    if (caller.role !== "super_admin") {
      return json(403, { success: false, message: "শুধু Super Admin Manager ID তৈরি করতে পারবেন।" }, origin);
    }
    role = "company_manager";
  } else if (action === "create_sub_manager") {
    const requestedRegion = typeof body.region === "string" ? body.region.toUpperCase() : "";
    const requestedType = typeof body.sub_manager_type === "string"
      ? body.sub_manager_type.toUpperCase()
      : (requestedRegion === "NB" || requestedRegion === "DHAKA" ? requestedRegion : "");
    if (!["NB", "DHAKA", "SB"].includes(requestedRegion)) {
      return json(400, { success: false, message: "Assigned Region NB, DHAKA অথবা SB হতে হবে।" }, origin);
    }
    if (!["NB", "DHAKA"].includes(requestedType)) {
      return json(400, { success: false, message: "Sub Manager Type NB অথবা DHAKA হতে হবে।" }, origin);
    }
    region = requestedRegion;
    role = requestedType === "NB" ? "nb_sub_manager" : "dhaka_sub_manager";
  } else {
    role = "counter_operator";
    counterId = typeof body.counter_id === "string" ? body.counter_id : null;
    region = typeof body.region === "string" ? body.region.toUpperCase() : "ALL";
    idType = typeof body.id_type === "string" ? body.id_type.toUpperCase() : "OPERATOR";
    scheduleRegions = Array.isArray(body.schedule_regions)
      ? [...new Set(body.schedule_regions.filter((value): value is string => typeof value === "string").map(value => value.toUpperCase()))]
      : [];
    if (!["OPERATOR", "AGENT"].includes(idType)) {
      return json(400, { success: false, message: "ID Type OPERATOR অথবা AGENT হতে হবে।" }, origin);
    }
    if (!scheduleRegions.length || scheduleRegions.some(value => !["NB", "DHAKA", "SB"].includes(value))) {
      return json(400, { success: false, message: "Schedule দেখার জন্য NB, DHAKA অথবা SB থেকে অন্তত একটি Region নির্বাচন করুন।" }, origin);
    }
    defaultBoardingPoint = typeof body.default_boarding_point === "string"
      ? body.default_boarding_point.trim()
      : "";

    if (!defaultBoardingPoint || defaultBoardingPoint.length > 160) {
      return json(400, { success: false, message: "Default Boarding Point নির্বাচন করুন।" }, origin);
    }

    const isCustomBoardingPoint = body.default_boarding_point_custom === true;
    if (!isCustomBoardingPoint) {
      let boardingQuery = admin.from("route_stops")
        .select("stop_name,routes!inner(company_id,region)")
        .eq("routes.company_id", companyId)
        .eq("can_board", true)
        .eq("stop_name", defaultBoardingPoint);
      if (region !== "ALL") boardingQuery = boardingQuery.eq("routes.region", region);
      const { data: boardingRows, error: boardingError } = await boardingQuery.limit(1);
      if (boardingError || !boardingRows?.length) {
        return json(400, { success: false, message: "নির্বাচিত Boarding Point এই Company ও Region-এর বৈধ Boarding Stop নয়।" }, origin);
      }
    }


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
    schedule_regions: scheduleRegions,
    default_boarding_point: defaultBoardingPoint,
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

  if (body.default_boarding_point_custom === true) {
    const { error: pointError } = await admin
      .from("company_boarding_points")
      .upsert({
        company_id: companyId,
        region: "NB",
        point_name: defaultBoardingPoint,
        created_by: authData.user.id,
      }, { onConflict: "company_id,region,point_name", ignoreDuplicates: true });
    if (pointError) {
      await admin.from("profiles").delete().eq("id", createdAuth.user.id);
      await admin.auth.admin.deleteUser(createdAuth.user.id);
      console.error("manage-company-users custom NB boarding point save failed", {
        company_id: companyId, code: pointError.code ?? null, message: pointError.message,
      });
      return json(500, {
        success: false,
        message: "Custom Boarding Point NB Schedule Library-তে সংরক্ষণ হয়নি। ID তৈরি করা হয়নি; আবার চেষ্টা করুন।",
        stage: "custom_boarding_point_save",
        code: pointError.code ?? "UNKNOWN",
      }, origin);
    }
  }

  const successMessage = role === "company_manager"
    ? "Manager Login ID তৈরি হয়েছে।"
    : role === "nb_sub_manager" || role === "dhaka_sub_manager"
      ? "Sub Manager Login ID তৈরি হয়েছে।"
      : "Counter Operator Login ID তৈরি হয়েছে।";

  return json(200, {
    success: true,
    message: successMessage,
    profile: {
      id: createdAuth.user.id,
      login_id: loginId,
      full_name: fullName,
      role,
      sub_manager_type: action === "create_sub_manager" ? (role === "nb_sub_manager" ? "NB" : "DHAKA") : null,
      company_id: companyId,
      counter_id: counterId,
      region,
      id_type: idType,
      schedule_regions: scheduleRegions,
      default_boarding_point: defaultBoardingPoint,
      is_active: true,
    },
  }, origin);
});
