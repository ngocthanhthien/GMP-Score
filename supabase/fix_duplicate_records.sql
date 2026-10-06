-- Dọn dòng điểm TRÙNG do bản app cũ ghi ra (VD id "2026-09|FD & CL|FD & CL|3" nằm cạnh id chuẩn "2026-09|FD & CL|3", cùng batch + cùng câu hỏi).
-- Dòng cũ đè giá trị Admin vừa sửa và làm điểm bị nhân đôi (VD 294/324 thay vì 147/162). Chạy 1 lần trong SQL Editor; an toàn chạy lại.
-- id chuẩn = "<batch>|<số thứ tự>". Chỉ xoá dòng id LẠ khi câu đó đã có dòng id chuẩn — dòng id lạ duy nhất (dữ liệu cũ thật) được giữ.

-- Xem trước: những dòng sẽ bị xoá
select d.batch, d.auditor, count(*) as so_dong
from public.gmp_records d
where not (left(d.id, length(d.batch) + 1) = d.batch || '|' and substr(d.id, length(d.batch) + 2) ~ '^[0-9]+$')
  and exists (
    select 1 from public.gmp_records c
    where c.batch = d.batch and c.cat is not distinct from d.cat and c.req is not distinct from d.req
      and left(c.id, length(c.batch) + 1) = c.batch || '|' and substr(c.id, length(c.batch) + 2) ~ '^[0-9]+$'
  )
group by d.batch, d.auditor order by d.batch;

-- Xoá
delete from public.gmp_records d
where not (left(d.id, length(d.batch) + 1) = d.batch || '|' and substr(d.id, length(d.batch) + 2) ~ '^[0-9]+$')
  and exists (
    select 1 from public.gmp_records c
    where c.batch = d.batch and c.cat is not distinct from d.cat and c.req is not distinct from d.req
      and left(c.id, length(c.batch) + 1) = c.batch || '|' and substr(c.id, length(c.batch) + 2) ~ '^[0-9]+$'
  );
