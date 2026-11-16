import { createClient } from "npm:@supabase/supabase-js@2";

// Only the BUSNEX Live and Redesign websites are allowed browser origins.
const allowedOrigins = [
  "https://busnex.vercel.app",
  "https://busnex-git-busnex-redesign-busnex.vercel.app",
];

function getCorsHeaders(origin: string | null) {
  const allowedOrigin =
    origin && allowedOrigins.includes(origin)
      ? origin
      : "https://busnex.vercel.app";

  return {
    "Access-Control-Allow-Origin": allowedOrigin,
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

function reply(
  data: unknown,
  status = 200,
  origin: string | null = null,
) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      ...getCorsHeaders(origin),
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
}

// Supports the current Supabase JSON secret format and legacy plain values.
function getKey(variable: string, legacyVariable: string): string {
  const value = Deno.env.get(variable);

  if (value) {
    try {
      const parsed = JSON.parse(value);
      if (typeof parsed === "string") return parsed;
      if (parsed && typeof parsed.default === "string") {
        return parsed.default;
      }
      return value;
    } catch {
      return value;
    }
  }

  return Deno.env.get(legacyVariable) ?? "";
}

Deno.serve(async (req: Request) => {
  let stage = "START";

  const origin = req.headers.get("origin");
  const send = (data: unknown, status = 200) =>
    reply(data, status, origin);

  console.log("BUSNEX LOGIN STARTED");

  const corsHeaders = getCorsHeaders(origin);

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return send({ error: "Method not allowed" }, 405);
  }

  // Reject browser requests from origins other than the two BUSNEX sites.
  if (origin && !allowedOrigins.includes(origin)) {
    return send({ error: "Origin not allowed" }, 403);
  }

  try {
    stage = "READ_CONFIGURATION";

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const secretKey = getKey(
      "SUPABASE_SECRET_KEYS",
      "SUPABASE_SERVICE_ROLE_KEY",
    );
    const publishableKey = getKey(
      "SUPABASE_PUBLISHABLE_KEYS",
      "SUPABASE_ANON_KEY",
    );

    if (!supabaseUrl || !secretKey || !publishableKey) {
      console.error("Configuration missing");
      return send({ error: "Server configuration error" }, 500);
    }

    stage = "CREATE_ADMIN_CLIENT";
    const admin = createClient(supabaseUrl, secretKey, {
      auth: {
        autoRefreshToken: false,
        persistSession: false,
        detectSessionInUrl: false,
      },
    });

    stage = "CREATE_AUTH_CLIENT";
    const authClient = createClient(supabaseUrl, publishableKey, {
      auth: {
        autoRefreshToken: false,
        persistSession: false,
        detectSessionInUrl: false,
      },
    });

    stage = "READ_REQUEST";
    const body = await req.json();

    const loginId = String(body.login_id ?? "")
      .trim()
      .toUpperCase();
    const password = String(body.password ?? "");

    if (
      !loginId ||
      !password ||
      loginId.length > 100 ||
      password.length > 128
    ) {
      return send({
        error: "Login ID or password is incorrect",
      }, 401);
    }

    stage = "FIND_PROFILE";
    const { data: profile, error: profileError } = await admin
      .from("profiles")
      .select(
        "id, login_id, full_name, role, company_id, counter_id, region, id_type, default_boarding_point, is_active",
      )
      .eq("login_id", loginId)
      .maybeSingle();

    if (profileError) {
      console.error("PROFILE_ERROR:", profileError.message);
      return send({
        error: "Profile lookup failed",
        details: profileError.message,
        code: profileError.code,
        stage,
      }, 500);
    }

    if (!profile) {
      return send({
        error: "Login ID or password is incorrect",
      }, 401);
    }

    // New database column: existing accounts default to true.
    if (profile.is_active === false) {
      console.warn("INACTIVE_PROFILE_LOGIN_BLOCKED:", profile.login_id);
      return send({
        error: "এই Login ID বর্তমানে Deactivated। Manager-এর সঙ্গে যোগাযোগ করুন।",
        stage: "CHECK_PROFILE_ACTIVE",
      }, 403);
    }

    // An Operator must also belong to an active Counter.
    if (profile.role === "counter_operator") {
      stage = "CHECK_COUNTER_STATUS";

      if (!profile.counter_id) {
        return send({
          error: "এই Operator ID-র সঙ্গে কোনো Counter যুক্ত নেই।",
          stage,
        }, 403);
      }

      const { data: counter, error: counterError } = await admin
        .from("counters")
        .select("id, is_active")
        .eq("id", profile.counter_id)
        .maybeSingle();

      if (counterError) {
        console.error("COUNTER_STATUS_ERROR:", counterError.message);
        return send({
          error: "Counter status lookup failed",
          details: counterError.message,
          code: counterError.code,
          stage,
        }, 500);
      }

      if (!counter || counter.is_active === false) {
        return send({
          error: "এই Counter বর্তমানে বন্ধ।",
          stage,
        }, 403);
      }
    }

    stage = "FIND_AUTH_USER";
    const { data: userData, error: userError } =
      await admin.auth.admin.getUserById(profile.id);

    if (userError || !userData.user?.email) {
      console.error("AUTH_USER_ERROR:", userError?.message);
      return send({
        error: "Account setup needs attention",
        stage,
      }, 500);
    }

    stage = "CHECK_PASSWORD";
    const { data: loginData, error: loginError } =
      await authClient.auth.signInWithPassword({
        email: userData.user.email,
        password,
      });

    if (loginError || !loginData.session) {
      console.error("LOGIN_ERROR:", loginError?.message);
      return send({
        error: "Login ID or password is incorrect",
      }, 401);
    }

    stage = "LOGIN_SUCCESS";
    console.log("BUSNEX LOGIN SUCCESS");

    // Return only the profile fields used by the website.
    return send({
      success: true,
      access_token: loginData.session.access_token,
      refresh_token: loginData.session.refresh_token,
      profile: {
        id: profile.id,
        login_id: profile.login_id,
        full_name: profile.full_name,
        role: profile.role,
        company_id: profile.company_id,
        counter_id: profile.counter_id,
        region: profile.region,
        id_type: profile.id_type,
        is_active: profile.is_active,
      },
    });
  } catch (error) {
    console.error(
      "BUSNEX ERROR AT:",
      stage,
      error instanceof Error ? error.message : "Unknown error",
    );

    return send({
      error: "Server error",
      stage,
    }, 500);
  }
});
