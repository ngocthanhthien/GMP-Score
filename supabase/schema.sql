-- ============================================================================
-- GMP Score App — Supabase schema
-- Chạy TOÀN BỘ file này 1 lần trong SQL Editor của project Supabase mới,
-- theo đúng thứ tự (từ trên xuống). An toàn để chạy lại (idempotent) nhờ
-- if not exists / create or replace / on conflict do nothing.
-- ============================================================================

-- ===== 1. Bảng thành viên (map 1-1 với auth.users) =====
create table if not exists public.gmp_members (
  user_id uuid primary key references auth.users(id) on delete cascade,
  employee_code text,
  display_name text not null,
  role text not null default 'user' check (role in ('admin','user')),
  disabled boolean not null default false,
  created_at timestamptz not null default now()
);

-- ===== 2. Kỳ chấm điểm (theo tháng) =====
create table if not exists public.gmp_periods (
  id text primary key, -- "YYYY-MM"
  functions jsonb not null default '[]'::jsonb, -- mảng mã Function lúc tạo kỳ
  status text not null default 'Đang chấm' check (status in ('Đang chấm','Đã chốt')),
  created_at timestamptz not null default now(),
  closed_at timestamptz,
  closed_by text, -- tên người chốt (hiển thị), không phải uuid
  updated_at timestamptz not null default now(), -- dùng cho delta-sync phía client, xem gmp_set_updated_at() bên dưới
  reset_at timestamptz -- mốc Admin "Reset kỳ" gần nhất: các máy khác thấy mốc đổi thì xoá bản sao cục bộ của kỳ này
);
alter table public.gmp_periods add column if not exists reset_at timestamptz;
create index if not exists gmp_periods_updated_at_idx on public.gmp_periods (updated_at);

-- ===== 3. Trạng thái nộp bài của 1 Function trong 1 kỳ =====
create table if not exists public.gmp_submissions (
  id text primary key, -- period||'|'||code  (bản CHÍNH THỨC) hoặc period||'|'||code||'|'||submitter_key (bài CÁ NHÂN của 1 Auditor)
  period text not null references public.gmp_periods(id) on delete cascade,
  code text not null,
  status text not null default 'DRAFT' check (status in ('DRAFT','SUBMITTED','LOCKED')),
  auditor text,
  submitter_key text, -- null = dòng chính thức; có giá trị = bài chấm cá nhân của 1 Auditor (Mã NV/tên đã safeName)
  submitter_name text, -- tên hiển thị của Auditor ứng với submitter_key (chỉ có ở dòng cá nhân)
  final_submitter text, -- chỉ có ở dòng chính thức: submitter_key của bài cá nhân đã được Admin chọn làm kết quả cuối cùng
  updated_at timestamptz not null default now(),
  submitted_at timestamptz,
  submitted_by text,
  locked_at timestamptz,
  locked_by text
);
create index if not exists gmp_submissions_period_idx on public.gmp_submissions(period);
create index if not exists gmp_submissions_period_code_idx on public.gmp_submissions(period,code);

-- ===== 4. Điểm từng câu hỏi =====
create table if not exists public.gmp_records (
  id text primary key, -- batch||'|'||i
  batch text not null,
  period text not null,
  date date,
  auditor text,
  code text not null,
  full_name text,
  cat text,
  req text,
  score smallint check (score in (0,1,2)),
  cls text,
  finding text,
  evidence text,
  images jsonb not null default '[]'::jsonb, -- ảnh nén base64 (dữ liệu cũ) hoặc {path,...} trỏ Storage (dữ liệu mới)
  updated_at timestamptz not null default now(), -- dùng cho delta-sync phía client, xem gmp_set_updated_at() bên dưới
  updated_by uuid references auth.users(id)
);
create index if not exists gmp_records_period_code_idx on public.gmp_records(period,code);
create index if not exists gmp_records_updated_at_idx on public.gmp_records (updated_at);

-- ===== 5. CAPA — lưu nguyên khối JSON (giống cấu trúc localStorage cũ) =====
create table if not exists public.gmp_capa (
  id text primary key default 'current',
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);

-- ===== 6. Checklist tuỳ biến — 1 khối JSON =====
create table if not exists public.gmp_checklist (
  id text primary key default 'current',
  data jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);

-- ===== 7. Settings — 1 khối JSON =====
create table if not exists public.gmp_settings (
  id text primary key default 'current',
  data jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);

-- ===== 7b. Danh sách người đánh giá (tầng "User" không cần tài khoản) =====
-- Chỉ là danh sách tên/mã NV để hiển thị ở màn hình chọn người dùng — KHÔNG
-- phải tài khoản đăng nhập, không có mật khẩu. Admin quản lý danh sách này
-- trong tab 👥 Quản lý người dùng.
create table if not exists public.gmp_auditors (
  id text primary key default 'current',
  data jsonb not null default '[]'::jsonb, -- mảng {name, employee_code}
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);

-- ===== 7c. Đếm lưu lượng ước tính theo ngày (Data & Egress Control) =====
-- 1 dòng/ngày (id = "YYYY-MM-DD"), tăng dồn qua gmp_bump_egress_daily() — dùng để
-- Admin theo dõi/khống chế traffic ước tính trong app, KHÔNG phải số Egress thật
-- của Supabase. Khoá theo ngày nên "reset mỗi ngày" tự xảy ra (ngày mới = dòng
-- mới), không cần cron/reset riêng.
create table if not exists public.gmp_egress_daily (
  id text primary key, -- "YYYY-MM-DD" theo giờ local của thiết bị đang cộng dồn
  total_bytes bigint not null default 0,
  updated_at timestamptz not null default now()
);

-- ===== 8. Nhật ký thao tác (server tự ghi) =====
create table if not exists public.gmp_audit_log (
  id bigserial primary key,
  at timestamptz not null default now(),
  actor uuid references auth.users(id),
  actor_name text,
  action text not null,
  detail jsonb
);
create index if not exists gmp_audit_log_at_idx on public.gmp_audit_log(at desc);

-- ============================================================================
-- 8b. Trigger tự cập nhật updated_at cho gmp_records/gmp_periods — dùng cho
-- delta-sync phía client (chỉ kéo bản ghi đổi từ mốc lần trước thay vì tải lại
-- toàn bộ lịch sử mỗi lần đồng bộ, xem EGRESS_AUDIT.md). gmp_submissions đã có
-- updated_at tự set trong RPC gmp_set_submission nên không cần trigger riêng.
-- ============================================================================
create or replace function public.gmp_set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_gmp_records_updated_at on public.gmp_records;
create trigger trg_gmp_records_updated_at
  before update on public.gmp_records
  for each row execute function public.gmp_set_updated_at();

drop trigger if exists trg_gmp_periods_updated_at on public.gmp_periods;
create trigger trg_gmp_periods_updated_at
  before update on public.gmp_periods
  for each row execute function public.gmp_set_updated_at();

-- ============================================================================
-- Hàm hỗ trợ kiểm tra quyền (SECURITY DEFINER -> bỏ qua RLS khi tự truy vấn
-- gmp_members, tránh đệ quy chính sách)
-- ============================================================================
-- "Member" ở đây nghĩa là CÓ một phiên Supabase hợp lệ — kể cả phiên ẩn danh
-- (anonymous sign-in). Đây là tầng "User" không cần email/mật khẩu, tương đương
-- hành vi bản offline cũ (không mật khẩu cho non-Admin). Chỉ Admin thật (bảng
-- gmp_members, role='admin') mới cần đăng nhập email/mật khẩu — xem gmp_is_admin().
create or replace function public.gmp_is_member()
returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() is not null;
$$;

create or replace function public.gmp_is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select role='admin' and not disabled from public.gmp_members where user_id = auth.uid()), false);
$$;

create or replace function public.gmp_display_name()
returns text language sql stable security definer set search_path = public as $$
  select display_name from public.gmp_members where user_id = auth.uid();
$$;

-- ============================================================================
-- RLS — mọi bảng chỉ cho SELECT trực tiếp; mọi ghi dữ liệu đi qua RPC bên dưới
-- ============================================================================
alter table public.gmp_members enable row level security;
alter table public.gmp_periods enable row level security;
alter table public.gmp_submissions enable row level security;
alter table public.gmp_records enable row level security;
alter table public.gmp_capa enable row level security;
alter table public.gmp_checklist enable row level security;
alter table public.gmp_settings enable row level security;
alter table public.gmp_auditors enable row level security;
alter table public.gmp_audit_log enable row level security;
alter table public.gmp_egress_daily enable row level security;

drop policy if exists gmp_members_select on public.gmp_members;
-- Chặt hơn các bảng khác: gmp_members chứa email Admin thật, không cho khách ẩn
-- danh đọc toàn bảng — chỉ cho xem đúng dòng của chính mình hoặc khi là Admin.
create policy gmp_members_select on public.gmp_members for select
  using (user_id = auth.uid() or public.gmp_is_admin());

drop policy if exists gmp_periods_select on public.gmp_periods;
create policy gmp_periods_select on public.gmp_periods for select using (public.gmp_is_member());

drop policy if exists gmp_submissions_select on public.gmp_submissions;
create policy gmp_submissions_select on public.gmp_submissions for select using (public.gmp_is_member());

drop policy if exists gmp_records_select on public.gmp_records;
create policy gmp_records_select on public.gmp_records for select using (public.gmp_is_member());

drop policy if exists gmp_capa_select on public.gmp_capa;
create policy gmp_capa_select on public.gmp_capa for select using (public.gmp_is_member());

drop policy if exists gmp_checklist_select on public.gmp_checklist;
create policy gmp_checklist_select on public.gmp_checklist for select using (public.gmp_is_member());

drop policy if exists gmp_settings_select on public.gmp_settings;
create policy gmp_settings_select on public.gmp_settings for select using (public.gmp_is_member());

-- Chặt hơn các bảng khác: gmp_auditors.data chứa Mã NV dùng làm "mật khẩu" đăng
-- nhập tầng User — không cho phiên thường/ẩn danh đọc trực tiếp bảng này (sẽ lộ
-- hết Mã NV qua console trình duyệt). Chỉ Admin đọc được nguyên bảng (để quản lý);
-- người khác lấy danh sách TÊN qua gmp_list_auditor_names() và xác thực mã qua
-- gmp_verify_auditor_code() — cả 2 đều không trả Mã NV về client.
drop policy if exists gmp_auditors_select on public.gmp_auditors;
create policy gmp_auditors_select on public.gmp_auditors for select using (public.gmp_is_admin());

drop policy if exists gmp_audit_log_select on public.gmp_audit_log;
create policy gmp_audit_log_select on public.gmp_audit_log for select using (public.gmp_is_admin());

drop policy if exists gmp_egress_daily_select on public.gmp_egress_daily;
create policy gmp_egress_daily_select on public.gmp_egress_daily for select using (public.gmp_is_member());

-- Không có policy insert/update/delete nào cho role authenticated/anon trên các
-- bảng trên — cố tình để trống, ép mọi client phải đi qua các hàm RPC bên dưới.

-- Lưu ý: phiên "anonymous sign-in" (tầng User không mật khẩu) vẫn mang JWT
-- role=authenticated (khác với role Postgres "anon" — role đó chỉ dành cho
-- request hoàn toàn chưa có JWT). Vì mọi phiên trong app (kể cả ẩn danh) đều
-- gọi supabase.auth.signInAnonymously() trước khi đọc dữ liệu, chỉ cần cấp
-- quyền cho "authenticated" là đủ.
grant usage on schema public to authenticated;
grant select on public.gmp_periods, public.gmp_submissions,
  public.gmp_records, public.gmp_capa, public.gmp_checklist, public.gmp_settings,
  public.gmp_auditors, public.gmp_members, public.gmp_audit_log to authenticated;

-- ============================================================================
-- RPC: ghi điểm 1 câu hỏi (mirror functionLocked/canEditFunction phía client)
-- ============================================================================
create or replace function public.gmp_save_record(p jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_period text := p->>'period';
  v_code text := p->>'code';
  v_submitter text := nullif(p->>'submitterKey','');
  v_sub_id text;
  v_locked boolean := false;
  v_submitted boolean := false;
  v_admin boolean := public.gmp_is_admin();
begin
  if not public.gmp_is_member() then raise exception 'Tài khoản không có quyền truy cập'; end if;
  if v_period is null or v_code is null then raise exception 'Thiếu period/code'; end if;

  -- Khoá luôn tính theo dòng CHÍNH THỨC (submitter_key is null), áp dụng chung cho cả bài cá nhân lẫn bài chính thức
  select (status='LOCKED') into v_locked from public.gmp_submissions where id = v_period||'|'||v_code and submitter_key is null;
  v_locked := coalesce(v_locked,false);
  if exists(select 1 from public.gmp_periods where id=v_period and status='Đã chốt') then v_locked := true; end if;
  if v_locked then raise exception 'Function/kỳ này đã bị khoá, không thể ghi điểm'; end if;

  -- "Đã nộp -> chỉ Admin sửa" tính theo ĐÚNG dòng đang ghi (bài cá nhân của Auditor này, hoặc dòng chính thức)
  v_sub_id := v_period||'|'||v_code || case when v_submitter is not null then '|'||v_submitter else '' end;
  select (status='SUBMITTED') into v_submitted from public.gmp_submissions where id = v_sub_id;
  if coalesce(v_submitted,false) and not v_admin then raise exception 'Đã nộp — chỉ Admin được sửa'; end if;

  insert into public.gmp_records(id,batch,period,date,auditor,code,full_name,cat,req,score,cls,finding,evidence,images,updated_at,updated_by)
  values(
    p->>'id', p->>'batch', v_period, nullif(p->>'date','')::date, p->>'auditor', v_code, p->>'full',
    p->>'cat', p->>'req', nullif(p->>'score','')::smallint, p->>'cls', p->>'finding', p->>'evidence',
    coalesce(p->'images','[]'::jsonb), now(), auth.uid()
  )
  on conflict (id) do update set
    batch=excluded.batch, period=excluded.period, date=excluded.date, auditor=excluded.auditor,
    code=excluded.code, full_name=excluded.full_name, cat=excluded.cat, req=excluded.req,
    score=excluded.score, cls=excluded.cls, finding=excluded.finding, evidence=excluded.evidence,
    images=excluded.images, updated_at=now(), updated_by=auth.uid();

  insert into public.gmp_audit_log(actor,actor_name,action,detail)
  values(auth.uid(), coalesce(public.gmp_display_name(), p->>'auditor'), 'save_record', jsonb_build_object('id',p->>'id','period',v_period,'code',v_code));
end; $$;

create or replace function public.gmp_delete_record(p_id text)
returns void language plpgsql security definer set search_path = public as $$
declare v_rec record; v_locked boolean;
begin
  if not public.gmp_is_member() then raise exception 'Tài khoản không có quyền truy cập'; end if;
  select * into v_rec from public.gmp_records where id=p_id;
  if v_rec is null then return; end if;
  select (status='LOCKED') into v_locked from public.gmp_submissions where id=v_rec.period||'|'||v_rec.code;
  if coalesce(v_locked,false) or exists(select 1 from public.gmp_periods where id=v_rec.period and status='Đã chốt') then
    raise exception 'Function/kỳ này đã bị khoá';
  end if;
  delete from public.gmp_records where id=p_id;
  insert into public.gmp_audit_log(actor,actor_name,action,detail)
  values(auth.uid(), public.gmp_display_name(), 'delete_record', jsonb_build_object('id',p_id));
end; $$;

-- ============================================================================
-- RPC: trạng thái nộp bài (DRAFT/SUBMITTED/LOCKED) — mirror setSubStatus/lockFunction
-- ============================================================================
create or replace function public.gmp_set_submission(
  p_period text, p_code text, p_status text, p_auditor text default null,
  p_submitter_key text default null, p_submitter_name text default null, p_final_submitter text default null
)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_admin boolean := public.gmp_is_admin();
  v_submitter text := nullif(p_submitter_key,'');
  v_id text := p_period||'|'||p_code || case when nullif(p_submitter_key,'') is not null then '|'||p_submitter_key else '' end;
  v_cur text;
begin
  if not public.gmp_is_member() then raise exception 'Tài khoản không có quyền truy cập'; end if;
  if p_status not in ('DRAFT','SUBMITTED','LOCKED') then raise exception 'Trạng thái không hợp lệ'; end if;

  select status into v_cur from public.gmp_submissions where id=v_id;
  if v_cur='LOCKED' then raise exception 'Đã khoá'; end if;
  if p_status='LOCKED' and not v_admin then raise exception 'Chỉ Admin được khoá'; end if;
  if v_cur='SUBMITTED' and p_status='DRAFT' and not v_admin then raise exception 'Đã nộp — chỉ Admin được sửa'; end if;

  -- gmp_submissions.period có khoá ngoại tới gmp_periods: nếu kỳ chưa tồn tại trên server (VD kỳ chỉ mới tạo cục bộ,
  -- hoặc user thường — không gọi được gmp_create_period) thì tự tạo kỳ "Đang chấm" để lượt nộp không bị lỗi FK mãi mãi.
  insert into public.gmp_periods(id,functions,status) values(p_period,'[]'::jsonb,'Đang chấm') on conflict (id) do nothing;

  insert into public.gmp_submissions(id,period,code,status,auditor,submitter_key,submitter_name,final_submitter,submitted_at,submitted_by,locked_at,locked_by,updated_at)
  values(v_id,p_period,p_code,p_status,p_auditor,v_submitter,nullif(p_submitter_name,''),nullif(p_final_submitter,''),
    case when p_status='SUBMITTED' then now() else null end,
    case when p_status='SUBMITTED' then coalesce(public.gmp_display_name(),p_auditor) else null end,
    case when p_status='LOCKED' then now() else null end,
    case when p_status='LOCKED' then public.gmp_display_name() else null end,
    now())
  on conflict(id) do update set
    status=excluded.status,
    auditor=coalesce(excluded.auditor, gmp_submissions.auditor),
    submitter_name=coalesce(excluded.submitter_name, gmp_submissions.submitter_name),
    final_submitter=coalesce(excluded.final_submitter, gmp_submissions.final_submitter),
    submitted_at=coalesce(excluded.submitted_at, gmp_submissions.submitted_at),
    submitted_by=coalesce(excluded.submitted_by, gmp_submissions.submitted_by),
    locked_at=coalesce(excluded.locked_at, gmp_submissions.locked_at),
    locked_by=coalesce(excluded.locked_by, gmp_submissions.locked_by),
    updated_at=now();

  insert into public.gmp_audit_log(actor,actor_name,action,detail)
  values(auth.uid(), coalesce(public.gmp_display_name(), p_auditor), 'set_submission', jsonb_build_object('period',p_period,'code',p_code,'status',p_status,'submitter_key',v_submitter));
end; $$;

-- ============================================================================
-- RPC: quản lý kỳ chấm điểm — mirror createNewPeriod/resetActivePeriod/lockWholePeriod
-- ============================================================================
create or replace function public.gmp_create_period(p_id text, p_functions jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.gmp_is_admin() then raise exception 'Chỉ Admin được tạo kỳ mới'; end if;
  insert into public.gmp_periods(id,functions,status,created_at)
  values(p_id, coalesce(p_functions,'[]'::jsonb), 'Đang chấm', now())
  on conflict (id) do nothing;
  insert into public.gmp_audit_log(actor,actor_name,action,detail)
  values(auth.uid(), public.gmp_display_name(), 'create_period', jsonb_build_object('id',p_id));
end; $$;

create or replace function public.gmp_reset_period(p_period text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.gmp_is_admin() then raise exception 'Chỉ Admin được reset kỳ'; end if;
  if exists(select 1 from public.gmp_periods where id=p_period and status='Đã chốt') then
    raise exception 'Kỳ đã chốt, không reset được';
  end if;
  delete from public.gmp_records where period=p_period;
  delete from public.gmp_submissions where period=p_period;
  insert into public.gmp_periods(id,functions,status,reset_at) values(p_period,'[]'::jsonb,'Đang chấm',now())
  on conflict (id) do update set reset_at=now();
  insert into public.gmp_audit_log(actor,actor_name,action,detail)
  values(auth.uid(), public.gmp_display_name(), 'reset_period', jsonb_build_object('period',p_period));
end; $$;

create or replace function public.gmp_lock_whole_period(p_period text)
returns void language plpgsql security definer set search_path = public as $$
declare v_functions jsonb; v_not_ready int;
begin
  if not public.gmp_is_admin() then raise exception 'Chỉ Admin được chốt kỳ'; end if;
  -- Kỳ có thể chưa tồn tại trên server (tạo cục bộ / tự tạo bởi gmp_set_submission với danh sách Function rỗng)
  insert into public.gmp_periods(id,functions,status) values(p_period,'[]'::jsonb,'Đang chấm') on conflict (id) do nothing;
  select functions into v_functions from public.gmp_periods where id=p_period;

  -- Danh sách Function rỗng -> chỉ kiểm tra các Function đã có bản chính thức trên server (client đã kiểm tra đủ danh sách)
  select count(*) into v_not_ready
  from jsonb_array_elements_text(v_functions) code
  where coalesce((select status from public.gmp_submissions where id=p_period||'|'||code),'DRAFT') not in ('SUBMITTED','LOCKED');
  if v_not_ready > 0 then raise exception 'Còn % Function chưa Gửi kết quả', v_not_ready; end if;

  -- Chỉ khoá các dòng CHÍNH THỨC — không đụng tới bài chấm cá nhân (submitter_key is not null)
  update public.gmp_submissions set status='LOCKED', locked_at=now(), locked_by=public.gmp_display_name(), updated_at=now()
  where period=p_period and submitter_key is null and status<>'LOCKED';
  update public.gmp_periods set status='Đã chốt', closed_at=now(), closed_by=public.gmp_display_name() where id=p_period;

  insert into public.gmp_audit_log(actor,actor_name,action,detail)
  values(auth.uid(), public.gmp_display_name(), 'lock_whole_period', jsonb_build_object('period',p_period));
end; $$;

-- ============================================================================
-- RPC: dọn dữ liệu chấm cá nhân đã dùng xong (Admin bấm thủ công, KHÔNG tự động)
-- Chỉ xoá bài cá nhân của các Function ĐÃ LOCKED (đã có kết quả chính thức) —
-- Function chưa chốt vẫn giữ nguyên toàn bộ bài cá nhân của các Auditor.
-- ============================================================================
create or replace function public.gmp_purge_finalized_candidates(p_period text)
returns integer language plpgsql security definer set search_path = public as $$
declare v_deleted int := 0; v_codes text[];
begin
  if not public.gmp_is_admin() then raise exception 'Chỉ Admin được dọn dữ liệu'; end if;

  select array_agg(code) into v_codes
  from public.gmp_submissions
  where period=p_period and submitter_key is null and status='LOCKED';
  if v_codes is null or array_length(v_codes,1) is null then return 0; end if;

  delete from public.gmp_records
  where period=p_period and code=any(v_codes) and batch <> (p_period||'|'||code);
  get diagnostics v_deleted = row_count;

  delete from public.gmp_submissions
  where period=p_period and code=any(v_codes) and submitter_key is not null;

  insert into public.gmp_audit_log(actor,actor_name,action,detail)
  values(auth.uid(), public.gmp_display_name(), 'purge_candidates', jsonb_build_object('period',p_period,'codes',v_codes,'deleted_records',v_deleted));
  return v_deleted;
end; $$;

-- ============================================================================
-- RPC: CAPA / Checklist / Settings — lưu nguyên khối JSON
-- ============================================================================
create or replace function public.gmp_save_capa(p_data jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.gmp_is_member() then raise exception 'Tài khoản không có quyền truy cập'; end if;
  insert into public.gmp_capa(id,data,updated_at,updated_by) values('current',p_data,now(),auth.uid())
  on conflict(id) do update set data=excluded.data, updated_at=now(), updated_by=auth.uid();
  insert into public.gmp_audit_log(actor,actor_name,action,detail)
  values(auth.uid(), public.gmp_display_name(), 'save_capa', '{}'::jsonb);
end; $$;

create or replace function public.gmp_save_checklist(p_data jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.gmp_is_admin() then raise exception 'Chỉ Admin được sửa checklist'; end if;
  insert into public.gmp_checklist(id,data,updated_at,updated_by) values('current',p_data,now(),auth.uid())
  on conflict(id) do update set data=excluded.data, updated_at=now(), updated_by=auth.uid();
  insert into public.gmp_audit_log(actor,actor_name,action,detail)
  values(auth.uid(), public.gmp_display_name(), 'save_checklist', '{}'::jsonb);
end; $$;

create or replace function public.gmp_save_settings(p_data jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.gmp_is_admin() then raise exception 'Chỉ Admin được sửa cài đặt'; end if;
  insert into public.gmp_settings(id,data,updated_at,updated_by) values('current',p_data,now(),auth.uid())
  on conflict(id) do update set data=excluded.data, updated_at=now(), updated_by=auth.uid();
  insert into public.gmp_audit_log(actor,actor_name,action,detail)
  values(auth.uid(), public.gmp_display_name(), 'save_settings', '{}'::jsonb);
end; $$;

create or replace function public.gmp_save_auditors(p_data jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.gmp_is_admin() then raise exception 'Chỉ Admin được sửa danh sách người đánh giá'; end if;
  insert into public.gmp_auditors(id,data,updated_at,updated_by) values('current',p_data,now(),auth.uid())
  on conflict(id) do update set data=excluded.data, updated_at=now(), updated_by=auth.uid();
  insert into public.gmp_audit_log(actor,actor_name,action,detail)
  values(auth.uid(), public.gmp_display_name(), 'save_auditors', '{}'::jsonb);
end; $$;

-- Danh sách TÊN dùng cho màn hình chọn người dùng — cố tình KHÔNG trả Mã NV,
-- gọi được bởi bất kỳ phiên nào (kể cả ẩn danh) vì đây là bước TRƯỚC khi xác
-- thực xong.
create or replace function public.gmp_list_auditor_names()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(
    (select jsonb_agg(name order by name) from (
       select distinct e->>'name' as name
       from public.gmp_auditors, jsonb_array_elements(data) e
       where id='current' and coalesce(e->>'name','')<>''
     ) t),
    '[]'::jsonb
  );
$$;

-- Xác thực Mã NV cho tầng "User" (rào cản trước khi vào app) — chỉ trả về
-- true/false, không bao giờ trả Mã NV thật về client. Coi Mã NV rỗng là
-- "chưa được Admin cấp quyền" -> luôn từ chối, không bypass được bằng ô trống.
create or replace function public.gmp_verify_auditor_code(p_name text, p_code text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(
    select 1
    from public.gmp_auditors, jsonb_array_elements(data) e
    where id='current'
      and lower(e->>'name') = lower(coalesce(p_name,''))
      and coalesce(trim(e->>'employee_code'),'') <> ''
      and e->>'employee_code' = p_code
  );
$$;

-- Cộng dồn traffic ước tính của 1 ngày — gọi bởi BẤT KỲ phiên nào (User thường
-- cũng tạo traffic), không chỉ Admin. Cố tình KHÔNG ghi gmp_audit_log ở đây: RPC
-- này được gọi định kỳ (piggyback theo vòng poll có sẵn), ghi audit log mỗi lần
-- gọi sẽ tự làm phình thêm egress — phản tác dụng với mục đích của chính nó.
create or replace function public.gmp_bump_egress_daily(p_date text, p_bytes bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.gmp_is_member() then raise exception 'Cần đăng nhập'; end if;
  if p_bytes is null or p_bytes<=0 then return; end if;
  insert into public.gmp_egress_daily(id,total_bytes,updated_at) values(p_date,p_bytes,now())
  on conflict(id) do update set total_bytes=public.gmp_egress_daily.total_bytes+excluded.total_bytes, updated_at=now();
end; $$;

-- ============================================================================
-- Storage: bucket ảnh gốc, private, chỉ member chưa bị vô hiệu hoá mới đọc/ghi
-- ============================================================================
insert into storage.buckets (id,name,public)
values ('gmp-mediasave','gmp-mediasave', false)
on conflict (id) do nothing;

drop policy if exists gmp_media_select on storage.objects;
create policy gmp_media_select on storage.objects for select
  using (bucket_id='gmp-mediasave' and public.gmp_is_member());

drop policy if exists gmp_media_insert on storage.objects;
create policy gmp_media_insert on storage.objects for insert
  with check (bucket_id='gmp-mediasave' and public.gmp_is_member());

drop policy if exists gmp_media_update on storage.objects;
create policy gmp_media_update on storage.objects for update
  using (bucket_id='gmp-mediasave' and public.gmp_is_member());

-- ============================================================================
-- Realtime: phát sự kiện INSERT/UPDATE/DELETE qua websocket cho các bảng dữ
-- liệu chính, để client kéo bản mới ngay khi có thay đổi thay vì chờ vòng
-- polling 30 giây. An toàn chạy lại nhiều lần (bỏ qua bảng đã có trong
-- publication thay vì báo lỗi trùng).
-- ============================================================================
do $$
declare t text;
begin
  foreach t in array array['gmp_records','gmp_submissions','gmp_periods','gmp_capa','gmp_checklist','gmp_settings','gmp_auditors'] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname='supabase_realtime' and schemaname='public' and tablename=t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- ============================================================================
-- Xong. Bước tiếp theo (xem HANDOFF.md mục 12 / EGRESS_AUDIT.md):
--   1) Authentication -> Sign In / Providers -> bật "Allow anonymous sign-ins"
--      (BẮT BUỘC — tầng "User" không mật khẩu dựa vào tính năng này).
--   2) Authentication -> Users -> tạo tài khoản Admin đầu tiên.
--   3) Chạy INSERT cấp quyền admin cho tài khoản đó vào gmp_members.
--   4) Deploy Edge Function admin-users (supabase/functions/admin-users).
--   5) Realtime đã tự bật qua khối lệnh phía trên — không cần thao tác gì thêm
--      trong Dashboard.
--   6) delta-sync (updated_at) cho gmp_records/gmp_periods đã có sẵn trong file
--      này (mục 8b) — KHÔNG cần chạy thêm add_updated_at.sql trên project mới
--      tạo từ file này. File add_updated_at.sql chỉ dùng để retrofit 1 project
--      CŨ đã chạy schema.sql từ trước khi có mục 8b.
-- ============================================================================
