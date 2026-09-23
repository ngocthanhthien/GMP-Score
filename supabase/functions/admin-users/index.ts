// supabase/functions/admin-users/index.ts
// Edge Function quản lý tài khoản (tạo / đổi vai trò / vô hiệu hoá) cho GMP Score App.
// Chạy bằng service_role phía server — client KHÔNG bao giờ thấy service_role key.
// Deploy: xem README - GMP Score Supabase.md mục 5.

import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const authHeader = req.headers.get("Authorization") || "";
  const jwt = authHeader.replace(/^Bearer /i, "");
  if (!jwt) return json({ error: "Thiếu Authorization" }, 401);

  // Xác thực người gọi bằng chính JWT của họ (anon key + Authorization header)
  const asCaller = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: userData, error: userErr } = await asCaller.auth.getUser(jwt);
  if (userErr || !userData?.user) return json({ error: "Phiên đăng nhập không hợp lệ" }, 401);
  const callerId = userData.user.id;

  // Từ đây dùng service_role để thao tác đặc quyền (bỏ qua RLS có chủ đích)
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  const { data: caller } = await admin
    .from("gmp_members")
    .select("role,disabled")
    .eq("user_id", callerId)
    .maybeSingle();
  if (!caller || caller.role !== "admin" || caller.disabled) {
    return json({ error: "Chỉ Admin được thao tác quản lý người dùng" }, 403);
  }

  let body: Record<string, unknown> = {};
  try {
    body = await req.json();
  } catch (_e) {
    // body rỗng/không hợp lệ -> xử lý như {}
  }
  const action = body.action as string | undefined;

  try {
    if (action === "list") {
      const { data: members, error } = await admin
        .from("gmp_members")
        .select("user_id,employee_code,display_name,role,disabled,created_at")
        .order("created_at", { ascending: true });
      if (error) throw error;

      const { data: authList, error: authErr } = await admin.auth.admin.listUsers({ perPage: 1000 });
      if (authErr) throw authErr;
      const emailOf: Record<string, string> = {};
      (authList?.users || []).forEach((u) => {
        emailOf[u.id] = u.email || "";
      });

      return json({
        members: (members || []).map((m) => ({ ...m, email: emailOf[m.user_id] || "" })),
      });
    }

    if (action === "create") {
      const email = String(body.email || "").trim();
      const password = String(body.password || "");
      const display_name = String(body.display_name || "").trim();
      const employee_code = body.employee_code ? String(body.employee_code).trim() : null;
      const role = body.role === "admin" ? "admin" : "user";

      if (!email || !password || !display_name) {
        return json({ error: "Thiếu email/mật khẩu/họ tên" }, 400);
      }
      if (password.length < 6) return json({ error: "Mật khẩu tối thiểu 6 ký tự" }, 400);

      const { data: created, error: createErr } = await admin.auth.admin.createUser({
        email,
        password,
        email_confirm: true,
      });
      if (createErr) throw createErr;

      const { error: memberErr } = await admin.from("gmp_members").insert({
        user_id: created.user!.id,
        display_name,
        employee_code,
        role,
        disabled: false,
      });
      if (memberErr) throw memberErr;

      return json({ ok: true, user_id: created.user!.id });
    }

    if (action === "setRole") {
      const user_id = String(body.user_id || "");
      const role = body.role === "admin" ? "admin" : "user";
      if (!user_id) return json({ error: "Thiếu user_id" }, 400);
      if (user_id === callerId && role !== "admin") {
        return json({ error: "Không thể tự hạ quyền chính mình" }, 400);
      }
      const { error } = await admin.from("gmp_members").update({ role }).eq("user_id", user_id);
      if (error) throw error;
      return json({ ok: true });
    }

    if (action === "setDisabled") {
      const user_id = String(body.user_id || "");
      const disabled = !!body.disabled;
      if (!user_id) return json({ error: "Thiếu user_id" }, 400);
      if (user_id === callerId && disabled) {
        return json({ error: "Không thể tự vô hiệu hoá chính mình" }, 400);
      }
      const { error } = await admin.from("gmp_members").update({ disabled }).eq("user_id", user_id);
      if (error) throw error;
      return json({ ok: true });
    }

    if (action === "resetPassword") {
      const user_id = String(body.user_id || "");
      const password = String(body.password || "");
      if (!user_id || password.length < 6) return json({ error: "Thiếu user_id hoặc mật khẩu < 6 ký tự" }, 400);
      const { error } = await admin.auth.admin.updateUserById(user_id, { password });
      if (error) throw error;
      return json({ ok: true });
    }

    return json({ error: "action không hợp lệ" }, 400);
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
