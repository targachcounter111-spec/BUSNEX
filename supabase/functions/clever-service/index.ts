import { createClient } from "npm:@supabase/supabase-js@2";

const allowedOrigins = new Set([
  "https://busnex.vercel.app",
  "https://busnex-git-busnex-redesign-busnex.vercel.app",
]);

function corsHeaders(origin: string | null) {
  const allowedOrigin = origin && allowedOrigins.has(origin) ? origin : "https://busnex.vercel.app";
  return {
    "Access-Control-Allow-Origin": allowedOrigin,
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

function reply(status: number, body: Record<string, unknown>, origin: string | null) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders(origin),
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
}

function getKey(primary: string, legacy: string): string {
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

  if (req.method === "OPTIONS") {
    return new Response("ok", { status: 200, headers: corsHeaders(origin) });
  }
  if (req.method !== "POST") {
    return reply(405, { success: false, message: "Method not allowed", stage: "method" }, origin);
  }
  if (origin && !allowedOrigins.has(origin)) {
    return reply(403, { success: false, message: "Origin not allowed", stage: "cors" }, origin);
  }

  let stage = "configuration";
  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const secretKey = getKey("SUPABASE_SECRET_KEYS", "SUPABASE_SERVICE_ROLE_KEY");
    const publishableKey = getKey("SUPABASE_PUBLISHABLE_KEYS", "SUPABASE_ANON_KEY");

    if (!supabaseUrl || !secretKey || !publishableKey) {
      return reply(500, { success: false, message: "Server configuration is incomplete", stage }, origin);
    }

    const admin = createClient(supabaseUrl, secretKey, {
      auth: { autoRefreshToken: false, persistSession: false, detectSessionInUrl: false },
    });
    const auth = createClient(supabaseUrl, publishableKey, {
      auth: { autoRefreshToken: false, persistSession: false, detectSessionInUrl: false },
    });

    stage = "request";
    let body: Record<string, unknown>;
    try {
      body = await req.json();
    } catch {
      return reply(400, { success: false, message: "Invalid JSON request", stage }, origin);
    }

    const loginId = typeof body.login_id === "string" ? body.login_id.trim().toUpperCase() : "";
    const password = typeof body.password === "string" ? body.password : "";

    if (!loginId || !password || loginId.length > 100 || password.length > 128) {
      return reply(401, { success: false, message: "Login ID or password is invalid", stage: "validation" }, origin);
    }

    stage = "profile_lookup";
    const { data: profile, error: profileError } = await admin
      .from("profiles")
      .select("id, login_id, full_name, role, company_id, counter_id, region, id_type, is_active")
      .eq("login_id", loginId)
      .maybeSingle();

    if (profileError) {
      return reply(500, {
        success: false,
        message: "Profile lookup failed",
        details: profileError.message,
        code: profileError.code,
        stage,
      }, origin);
    }
    if (!profile) {
      return reply(401, { success: false, message: "Login ID or password is incorrect", stage }, origin);
    }
    if (profile.is_active === false) {
      return reply(403, { success: false, message: "এই Login ID বর্তমানে Deactivated। Manager-এর সঙ্গে যোগাযোগ করুন।", stage: "inactive_profile" }, origin);
    }

    if (profile.role === "counter_operator") {
      stage = "counter_status";
      if (!profile.counter_id) {
        return reply(403, { success: false, message: "এই Operator ID-র সঙ্গে Counter যুক্ত নেই।", stage }, origin);
      }
      const { data: counter, error: counterError } = await admin
        .from("counters")
        .select("id, is_active")
        .eq("id", profile.counter_id)
        .maybeSingle();

      if (counterError) {
        return reply(500, {
          success: false,
          message: "Counter status lookup failed",
          details: counterError.message,
          code: counterError.code,
          stage,
        }, origin);
      }
      if (!counter || counter.is_active === false) {
        return reply(403, { success: false, message: "এই Counter বর্তমানে বন্ধ।", stage }, origin);
      }
    }

    stage = "auth_user_lookup";
    const { data: authUserData, error: authUserError } = await admin.auth.admin.getUserById(profile.id);
    if (authUserError || !authUserData.user?.email) {
      return reply(401, {
        success: false,
        message: "Login ID or password is incorrect",
        details: authUserError?.message ?? "Auth user email not found",
        stage,
      }, origin);
    }

    stage = "password_signin";
    const { data: signInData, error: signInError } = await auth.auth.signInWithPassword({
      email: authUserData.user.email,
      password,
    });

    if (signInError || !signInData.session) {
      return reply(401, {
        success: false,
        message: "Login ID or password is incorrect",
        details: signInError?.message,
        stage,
      }, origin);
    }

    return reply(200, {
      success: true,
      access_token: signInData.session.access_token,
      refresh_token: signInData.session.refresh_token,
      profile: {
        id: profile.id,
        login_id: profile.login_id,
        full_name: profile.full_name,
        role: profile.role,
        company_id: profile.company_id,
        counter_id: profile.counter_id,
        region: profile.region,
        id_type: profile.id_type,
      },
    }, origin);
  } catch (error) {
    return reply(500, {
      success: false,
      message: "Unexpected login server error",
      details: error instanceof Error ? error.message : String(error),
      stage,
    }, origin);
  }
});
