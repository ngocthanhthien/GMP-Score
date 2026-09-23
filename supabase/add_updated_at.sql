-- LƯU Ý: schema.sql hiện tại (mục "8b.") đã tích hợp sẵn cột updated_at + trigger này
-- cho project MỚI tạo từ schema.sql — KHÔNG cần chạy file này trên project mới
-- (mnhlddcvbzihhnnirhiz.supabase.co). File này chỉ dùng để retrofit 1 project CŨ đã
-- chạy schema.sql từ trước khi có mục 8b (ví dụ project cũ thhevdrgbxvyatfvtyrh).
--
-- Thêm cột updated_at + trigger tự cập nhật cho gmp_records và gmp_periods.
-- An toàn chạy lại nhiều lần (idempotent) — dùng if not exists / create or replace / drop trigger if exists.
-- Sau khi chạy file này, KHÔNG cần sửa gì thêm ở client (ready/index.html): pullTables() đã có sẵn
-- logic tự phát hiện cột này qua thử-lỗi-rồi-quay-lại-full-select, nên sẽ tự động chuyển sang
-- delta sync (chỉ tải bản ghi mới đổi thay vì toàn bộ lịch sử mỗi lần đồng bộ) ngay khi cột tồn tại,
-- không cần deploy lại app.
--
-- gmp_submissions đã có sẵn updated_at từ trước (không cần chạy lại cho bảng này).

create or replace function public.gmp_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- gmp_records
alter table public.gmp_records
  add column if not exists updated_at timestamptz not null default now();
create index if not exists gmp_records_updated_at_idx on public.gmp_records (updated_at);
drop trigger if exists trg_gmp_records_updated_at on public.gmp_records;
create trigger trg_gmp_records_updated_at
  before update on public.gmp_records
  for each row execute function public.gmp_set_updated_at();

-- gmp_periods
alter table public.gmp_periods
  add column if not exists updated_at timestamptz not null default now();
create index if not exists gmp_periods_updated_at_idx on public.gmp_periods (updated_at);
drop trigger if exists trg_gmp_periods_updated_at on public.gmp_periods;
create trigger trg_gmp_periods_updated_at
  before update on public.gmp_periods
  for each row execute function public.gmp_set_updated_at();

-- Ghi chú: các bảng cấu hình 1-dòng (gmp_capa, gmp_checklist, gmp_settings, gmp_auditors) CỐ Ý
-- không thêm updated_at ở đây — mỗi bảng chỉ có đúng 1 dòng JSONB (id='current'), delta sync
-- theo dòng không giúp ích nhiều cho các bảng này; app vẫn full-select chúng như trước (payload
-- các bảng này nhỏ, không phải nguồn egress lớn — xem EGRESS_AUDIT.md).
