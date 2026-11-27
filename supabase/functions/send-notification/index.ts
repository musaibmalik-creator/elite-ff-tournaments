import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function base64url(input: Uint8Array | string) {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : input;
  let binary = "";
  bytes.forEach((b) => binary += String.fromCharCode(b));
  return btoa(binary).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

function pemToArrayBuffer(pem: string) {
  const clean = pem.replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "").replace(/\s/g, "");
  const binary = atob(clean);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}

async function getGoogleAccessToken(service: any) {
  const now = Math.floor(Date.now() / 1000);
  const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claim = base64url(JSON.stringify({
    iss: service.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  }));
  const unsigned = header + "." + claim;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToArrayBuffer(service.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(unsigned),
  );
  const assertion = unsigned + "." + base64url(new Uint8Array(signature));
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  const result = await response.json();
  if (!response.ok) throw new Error(result.error_description || "Google OAuth token failed");
  return result.access_token as string;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    if (req.method !== "POST") throw new Error("Method not allowed");

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceJson = Deno.env.get("FIREBASE_SERVICE_ACCOUNT");
    if (!serviceJson) throw new Error("FIREBASE_SERVICE_ACCOUNT secret is missing");

    const authHeader = req.headers.get("Authorization") || "";
    const jwt = authHeader.replace(/^Bearer\s+/i, "");
    if (!jwt) throw new Error("Login required");

    const adminClient = createClient(supabaseUrl, serviceKey);
    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: "Bearer " + jwt } },
    });
    const { data: userData, error: userError } = await userClient.auth.getUser();
    if (userError || !userData.user) throw new Error("Invalid login session");

    const { data: profile, error: profileError } = await adminClient
      .from("profiles").select("role").eq("id", userData.user.id).maybeSingle();
    if (profileError || profile?.role !== "admin") throw new Error("Admin access required");

    const payload = await req.json();
    const type = payload.type;
    let title = "";
    let body = "";
    let tournamentId: string | null = null;
    let recipients: string[] = [];

    if (type === "room_released") {
      tournamentId = String(payload.tournament_id || "");
      if (!tournamentId) throw new Error("Tournament ID required");

      const [{ data: tournament, error: tError }, { data: room, error: rError }, { data: players, error: pError }] = await Promise.all([
        adminClient.from("tournaments").select("id,name").eq("id", tournamentId).maybeSingle(),
        adminClient.from("tournament_room_details")
          .select("room_id,room_password,custom_id,custom_password")
          .eq("tournament_id", tournamentId).maybeSingle(),
        adminClient.from("players").select("user_id").eq("tournament_id", tournamentId).not("user_id", "is", null),
      ]);
      if (tError || !tournament) throw new Error("Tournament not found");
      if (rError) throw new Error("Unable to verify room details");
      if (pError) throw new Error("Unable to load registered players");
      const hasRoom = !!(room?.room_id || room?.room_password || room?.custom_id || room?.custom_password);
      if (!hasRoom) throw new Error("Room details are empty");
      recipients = [...new Set((players || []).map((p: any) => p.user_id).filter(Boolean))];
      title = "🎮 Room Details Released!";
      body = tournament.name + ": Room ID and Password are now available. Open your tournament dashboard.";
    } else if (type === "broadcast") {
      title = String(payload.title || "").trim().slice(0, 100);
      body = String(payload.body || "").trim().slice(0, 500);
      if (!title || !body) throw new Error("Notification title and message are required");
      const { data: users, error } = await adminClient.from("profiles").select("id");
      if (error) throw new Error("Unable to load users");
      recipients = [...new Set((users || []).map((u: any) => u.id).filter(Boolean))];
    } else {
      throw new Error("Unknown notification type");
    }

    if (!recipients.length) {
      return new Response(JSON.stringify({ success: true, sent: 0, message: "No recipients yet" }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const rows = recipients.map((user_id) => ({
      user_id, title, body, notification_type: type, tournament_id: tournamentId,
    }));
    const { error: insertError } = await adminClient.from("user_notifications").insert(rows);
    if (insertError) throw new Error("Notification history save failed: " + insertError.message);

    const { data: subscriptions, error: subError } = await adminClient
      .from("push_subscriptions").select("id,user_id,fcm_token").in("user_id", recipients);
    if (subError) throw new Error("Unable to load push subscriptions");

    const service = JSON.parse(serviceJson);
    const accessToken = await getGoogleAccessToken(service);
    const projectId = service.project_id;
    let sent = 0;
    let failed = 0;
    const invalidIds: string[] = [];

    for (const sub of subscriptions || []) {
      const response = await fetch(
        "https://fcm.googleapis.com/v1/projects/" + projectId + "/messages:send",
        {
          method: "POST",
          headers: {
            "Authorization": "Bearer " + accessToken,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            message: {
              token: sub.fcm_token,
              notification: { title, body },
              data: {
                type,
                tournamentId: tournamentId || "",
                url: tournamentId
                  ? "https://elite-ff-tournaments-nine.vercel.app/user.html?tournament=" + tournamentId
                  : "https://elite-ff-tournaments-nine.vercel.app/user.html",
              },
            },
          }),
        },
      );
      if (response.ok) sent++;
      else {
        failed++;
        const detail = await response.text();
        if (detail.includes("UNREGISTERED") || detail.includes("registration-token-not-registered")) {
          invalidIds.push(sub.id);
        }
      }
    }

    if (invalidIds.length) {
      await adminClient.from("push_subscriptions").delete().in("id", invalidIds);
    }

    return new Response(JSON.stringify({
      success: true, recipients: recipients.length, pushSent: sent, pushFailed: failed,
    }), { headers: { ...corsHeaders, "Content-Type": "application/json" } });
  } catch (error) {
    return new Response(JSON.stringify({ error: error.message || String(error) }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
