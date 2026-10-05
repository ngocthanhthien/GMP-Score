-- Chạy 1 lần trong SQL Editor SAU khi chạy lại supabase/schema.sql (bản có tự tạo kỳ trong gmp_set_submission).
-- Tạo các kỳ còn thiếu trên server cho mọi kỳ đã có dữ liệu chấm (gmp_records) — an toàn chạy lại nhiều lần.
-- Kỳ cũ sẽ ở trạng thái "Đang chấm": Admin vào tab Phê duyệt chốt/đối chiếu lại nếu cần.
insert into public.gmp_periods(id, functions, status)
select distinct period, '[]'::jsonb, 'Đang chấm'
from public.gmp_records
where period is not null and period <> ''
on conflict (id) do nothing;

select id, status from public.gmp_periods order by id;
