-- Chạy 1 lần trong SQL Editor (quyền postgres, bỏ qua RLS). An toàn chạy lại.
-- 1) Xoá dữ liệu MẪU (SEED) do các bản app cũ tự nạp rồi đẩy lên server (kỳ 2026-06, batch "2026-06-01|June.2026").
delete from public.gmp_records where batch = '2026-06-01|June.2026';
-- 2) Xoá kỳ 2026-06 nếu không còn dòng điểm thật nào (bài nộp của kỳ đó tự xoá theo qua khoá ngoại).
delete from public.gmp_periods p
where p.id = '2026-06' and not exists (select 1 from public.gmp_records r where r.period = p.id);
-- 3) Xoá kỳ/bài nộp/bộ đếm dùng để TEST tự động (kỳ 2099-12, ngày 2099-12-31).
delete from public.gmp_periods where id = '2099-12';
delete from public.gmp_egress_daily where id = '2099-12-31';
-- 4) (Tuỳ chọn) Đặt lại bộ đếm egress ước tính của hôm nay nếu đã bị thổi phồng bởi lỗi đồng bộ cũ:
-- update public.gmp_egress_daily set total_bytes = 0 where id = to_char(now() at time zone 'Asia/Ho_Chi_Minh','YYYY-MM-DD');

select period, count(*) as so_dong_diem from public.gmp_records group by period order by period;
select id, status from public.gmp_periods order by id;
