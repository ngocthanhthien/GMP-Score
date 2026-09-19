# Audit Egress Supabase — index.html (GMP-Score)

Phạm vi: toàn bộ `index.html` (2317 dòng; các dòng 621/628/640/641/667 là thư viện minified — ExcelJS/JSZip/PDF — không audit nội dung thư viện, chỉ audit code app tự viết). App dùng Supabase Auth (anonymous + email/password), Postgres (7 bảng qua RPC), Storage, Realtime.

## 0. Trạng thái triển khai (cập nhật 2026-09-20)

Cả 3 vấn đề top-1/2/3 bên dưới **đã sửa trong `index.html`** và đã test bằng cách monkey-patch `SB` (không đụng project Supabase thật — xem `HANDOFF.md` mục 12.7 về phương pháp này):

| # | Vấn đề | Trạng thái |
|---|---|---|
| 1 | `pullAll()` full-table mọi lúc | ✅ Tách `pullTables(tables,silent,force)` — Realtime chỉ kéo đúng bảng vừa đổi; poller giãn chu kỳ khi Realtime khoẻ; **+ delta-sync thật** theo `updated_at` cho `gmp_records`/`gmp_periods`/`gmp_submissions`, tự fallback về full-select nếu cột chưa tồn tại (an toàn dùng ngay cả khi chưa chạy SQL bên dưới) |
| 2 | Ảnh base64 nhúng trong cột DB | ✅ Ảnh mới upload Storage thành công → chỉ lưu `path`, không nhúng base64 vào bản ghi; hiển thị qua signed URL (cache theo TTL); Excel export tải ảnh từ Storage khi cần. Ảnh cũ / lúc offline vẫn giữ base64 như trước — không mất dữ liệu, không phá tính năng offline |
| 3 | Realtime nghe cả 7 bảng chỉ để refetch toàn bộ | ✅ Gộp theo đúng (các) bảng đổi trong cửa sổ debounce 400ms, chỉ kéo lại bảng đó |

**Việc cần bạn làm để kích hoạt delta-sync thật cho `gmp_records`/`gmp_periods`** (hiện 2 bảng này tự fallback về full-select vì có thể chưa có cột `updated_at`): chạy [`supabase/add_updated_at.sql`](supabase/add_updated_at.sql) trong Supabase SQL Editor — an toàn chạy lại nhiều lần, không cần sửa gì thêm ở client. `gmp_submissions` đã có sẵn cột này nên đã chạy delta-sync thật ngay từ bây giờ.

**Chưa làm / cần quyết định thêm:**
- Ảnh cũ đã đồng bộ lên server từ trước vẫn còn base64 trong DB (không migrate ngược — cần biết rõ bucket ACL/khối lượng dữ liệu trước khi làm, xem mục 2 gốc bên dưới).
- Quick win #3 (limit tạm thời) **không làm** vì rủi ro âm thầm làm rơi dữ liệu lịch sử của tab Lịch sử — cần delta-sync thật (mục 1) giải quyết đúng gốc thay vì limit.
- Bucket `gmp-mediasave`: dùng `createSignedUrl` nên hoạt động bất kể bucket public hay private — nhưng cần bucket có policy SELECT cho phiên hiện tại (anon/authenticated), nếu chưa có, ảnh mới sẽ không hiển thị được (không lỗi cứng — `resolveImgUrl` trả rỗng, ảnh chỉ không hiện) và cần bạn kiểm tra Storage policies.

## 1. Tổng quan

**Mức độ: Cao.**
Lý do: `pullAll()` gọi `select("*")` không lọc, không phân trang, không delta-sync trên **7 bảng cùng lúc** — trong đó `gmp_records` nhúng **ảnh base64 ngay trong cột JSON**. Hàm này được gọi lặp lại theo 2 cơ chế song song: poll mỗi 30s **và** debounce 400ms sau **mọi** sự kiện Realtime trên **mọi** trong 7 bảng, cho từng client đang mở app.

**Top nguồn lãng phí (ước lượng thô):**

1. **`pullAll()` full-table, không lọc** ([index.html:1888-1913](index.html:1888)) — tải lại toàn bộ lịch sử `gmp_records` (kèm ảnh base64) mỗi lần, kể cả khi chỉ 1 dòng đổi. Checklist gốc có ~800 hạng mục (`SEED`), mỗi kỳ đánh giá (tháng) tạo ~800 record; sau 6-12 tháng bảng có thể lên 5.000-10.000 dòng. Nếu ~15% dòng có 1 ảnh nén ~200-400KB (base64 ~270-540KB), một lần `pullAll` có thể kéo **150-500+ MB** — và việc này lặp lại mỗi 30s hoặc mỗi lần có ai đó sửa 1 ô.
2. **Ảnh lưu 2 nơi, nơi đọc lại là bản nặng nhất**: ảnh được nén rồi nhúng base64 vào `gmp_records.images` (đọc lại liên tục qua `select("*")`), đồng thời cũng upload file gốc lên Storage bucket `gmp-mediasave` ([index.html:1058](index.html:1058)) nhưng **không nơi nào trong code đọc lại từ Storage** (không có `createSignedUrl`/`getPublicUrl`) — bản Storage chỉ để backup thủ công, còn bản base64 trong DB mới là thứ bị tải lại liên tục.
3. **Realtime nghe cả bảng, không filter, chỉ để trigger refetch toàn bộ** ([index.html:1932-1937](index.html:1932)): mỗi thay đổi nhỏ (vd 1 người chấm 1 mục) phát ra payload `postgres_changes` (chứa row đầy đủ, có thể kèm ảnh) qua WebSocket, nhưng code chỉ dùng nó để gọi lại `pullAll()` REST — tức là **tải 2 lần** cho cùng một thay đổi.

## 2. Danh sách vấn đề (ưu tiên giảm dần)

| # | Vấn đề | File:dòng | Ảnh hưởng |
|---|--------|-----------|-----------|
| 1 | `pullAll()` select(*) toàn bộ 7 bảng, không filter/pagination/delta | [index.html:1888-1913](index.html:1888) | Cao |
| 2 | Ảnh base64 nhúng trong cột DB (`gmp_records.images`), bị tải lại theo #1 | [index.html:1019](index.html:1019), [index.html:1432](index.html:1432), [index.html:1863](index.html:1863) (map) | Cao |
| 3 | Realtime `event:"*"`, không filter, trên 7 bảng — chỉ để trigger refetch | [index.html:1930-1937](index.html:1930) | Trung bình-Cao |
| 4 | Poller `setInterval` 30s không dừng khi tab ẩn (`document.hidden`) | [index.html:1913](index.html:1913) | Trung bình |
| 5 | `flushPending()` đẩy từng item tuần tự qua RPC riêng lẻ (N+1 request) thay vì gộp batch | [index.html:1862-1868](index.html:1862) | Thấp-Trung bình |
| 6 | Upload Storage không đặt `cacheControl` dài hạn | [index.html:1058](index.html:1058) | Thấp |

### #1 — `pullAll()` không filter/pagination/delta sync
```js
const [rp,rs,rr,rc,rk,rt,ra]=await Promise.all([
  SB.from("gmp_periods").select("*"),
  SB.from("gmp_submissions").select("*"),
  SB.from("gmp_records").select("*"),   // <-- toàn bộ lịch sử, kèm ảnh base64
  ...
]);
```
Mỗi lần gọi (30s/lần, hoặc 400ms sau mọi realtime event) tải lại **toàn bộ** dữ liệu từ trước tới giờ, không chỉ phần thay đổi. Đây là nguồn egress lớn nhất và bị nhân lên bởi tần suất gọi.

**Cách sửa (delta sync theo `updated_at`, giữ nguyên cơ chế chống ghi đè `pendKeys` đã có):**
```js
let lastSync = {}; // per table, load từ localStorage
async function pullDelta(){
  const since = lastSync.gmp_records || '1970-01-01T00:00:00Z';
  const { data } = await SB.from("gmp_records")
    .select("*")                     // hoặc bớt cột nếu tách được ảnh (xem #2)
    .gt("updated_at", since)
    .order("updated_at", { ascending: true })
    .limit(500);
  if (data?.length) {
    for (const row of data) { if (!pendKeys.has(pendKey("record", row.id))) await dbPut(mapServerRecord(row)); }
    lastSync.gmp_records = data[data.length-1].updated_at;
  }
}
```
Yêu cầu bảng có cột `updated_at` (trigger auto-update) + index. Xóa record cần cơ chế soft-delete (`deleted_at`) để client biết xoá cục bộ.

### #2 — Ảnh base64 trong DB
```js
// hiện tại: nén xong nhúng base64 vào record
res({name:file.name,data:c.toDataURL("image/jpeg",0.72)});
...
im.images.push(...); // -> lưu vào CURRENT.rows[i].images -> SB.rpc("gmp_save_record",{p}) -> lưu trong cột JSON
```
Vì `uploadImageToStorage()` ([index.html:1054](index.html:1054)) đã upload file gốc lên Storage song song, DB chỉ nên giữ **đường dẫn**, không giữ base64:
```js
// record chỉ lưu path, không lưu data
im.path = "Mediasave/"+period+"/"+fname;   // thay vì im.data (base64) lưu trong DB
// hiển thị: dùng getPublicUrl (nếu bucket public) hoặc createSignedUrls gộp+cache (xem fix-patterns #11)
const { data } = SB.storage.from('gmp-mediasave').getPublicUrl(im.path);
```
*Lưu ý*: đây là thay đổi schema (cột `images` đổi từ base64 sang path) — cần script migrate dữ liệu cũ và cập nhật `mapServerRecord`, `thumbsHtml`, export Excel (`buildWorkbookBlob` đang dùng `im.data` trực tiếp để nhúng ảnh vào file xlsx — vẫn cần base64 ở bước export, nhưng có thể fetch từ Storage lúc export thay vì lưu sẵn trong DB).

### #3 — Realtime không filter, chỉ để trigger refetch toàn bộ
```js
// hiện tại
REALTIME_TABLES.forEach(t=>{
  realtimeChannel.on("postgres_changes",{event:"*",schema:"public",table:t},scheduleRealtimePull);
});
```
Payload đầy đủ (kèm ảnh nếu có) được gửi qua WebSocket dù code không dùng nó — chỉ dùng để biết "có gì đó đổi" rồi gọi lại REST. Hai lựa chọn:
- Nếu giữ kiến trúc "báo hiệu rồi pull": chuyển sang **Broadcast** (nhẹ, không kèm row data) thay vì `postgres_changes`.
- Nếu áp dụng delta sync (#1): giữ `postgres_changes` nhưng đổi `pullAll()` thành `pullDelta()` khi trigger, không đổi cấu trúc filter theo bảng vì app cần đồng bộ toàn bộ dữ liệu chung (không theo user/area riêng).

### #4 — Poller bỏ qua tab ẩn
```js
function startPoller(){clearInterval(pollTimer);pollTimer=setInterval(()=>{if(!dirtyEval&&!syncBusy&&navigator.onLine)pullAll(true).catch(()=>{});},30000);}
```
Nếu người dùng mở app trong tab nền (không đóng), vẫn tốn 1 request full-table mỗi 30s vô thời hạn.
```js
pollTimer=setInterval(()=>{
  if(document.hidden) return;
  if(!dirtyEval&&!syncBusy&&navigator.onLine)pullAll(true).catch(()=>{});
},30000);
document.addEventListener("visibilitychange",()=>{ if(!document.hidden) pullAll(true).catch(()=>{}); });
```

### #5 — `flushPending` gửi tuần tự N request
```js
for(const it of items){ try{await pushOne(it);await pendDel(it.key);}catch(e){} }
```
Nếu người dùng offline lâu rồi có mạng lại với nhiều thay đổi chờ (vd sửa cả 1 khu vực ~50 mục), mỗi mục là 1 round-trip HTTP riêng. Vì các `kind` khác nhau gọi RPC khác nhau, khó gộp thành 1 RPC chung — nhưng có thể **chạy song song có giới hạn** (giảm thời gian, không giảm số byte, nhưng giảm overhead header/TLS lặp lại):
```js
const CH_SIZE = 5;
for (let i=0;i<items.length;i+=CH_SIZE){
  await Promise.all(items.slice(i,i+CH_SIZE).map(it=>pushOne(it).then(()=>pendDel(it.key)).catch(()=>{})));
}
```
Về lâu dài: thêm RPC `gmp_save_records_batch(p_records jsonb[])` để gộp nhiều `record` cùng loại thành 1 lệnh gọi.

### #6 — Upload Storage không set cacheControl
```js
await SB.storage.from("gmp-mediasave").upload(fname,file,{upsert:false,contentType:file.type||"image/jpeg"});
```
Tên file đã có timestamp (`Date.now()`) nên bất biến — nên set cache dài vì ảnh này không đổi:
```js
await SB.storage.from("gmp-mediasave").upload(fname,file,{upsert:false,contentType:file.type||"image/jpeg",cacheControl:"31536000"});
```
Ảnh hưởng thấp vì hiện app không đọc lại từ Storage — chỉ có giá trị nếu sau này có tính năng xem lại ảnh từ Storage.

## 3. Quick Wins (làm trước, ≤15 phút mỗi mục)

- [ ] Dừng poller khi `document.hidden` (#4) — 5 dòng, không đổi hành vi khi tab đang mở.
- [ ] Thêm `cacheControl:"31536000"` vào `uploadImageToStorage` (#6) — 1 dòng.
- [ ] Thêm `.limit(1000)` tạm thời cho `gmp_records` trong `pullAll()` như biện pháp chặn tăng vô hạn trong lúc chờ làm delta sync đầy đủ — giảm rủi ro egress tăng đột biến khi bảng phình to, nhưng **không thay thế** cho việc filter theo `updated_at` (chỉ giảm trần, không giảm tần suất gọi).
- [ ] Đổi `flushPending` sang gửi song song theo lô (#5) — giảm thời gian đồng bộ khi có nhiều thay đổi chờ.

## 4. Đề xuất dài hạn

- **Delta sync thực sự** cho `pullAll()` (#1): thêm cột `updated_at` (trigger) cho cả 7 bảng, lưu mốc đồng bộ cuối theo bảng trong `localStorage`, chỉ `pullAll` full 1 lần đầu tiên khi mở app, các lần sau chỉ `gt('updated_at', last)`.
- **Tách ảnh khỏi cột JSON** (#2): `gmp_records.images` chỉ lưu `path`/`bucket`, ảnh thật ở Storage (đã có sẵn hạ tầng upload, chỉ thiếu bước đọc lại + đổi schema). Đây là thay đổi có tác động lớn nhất đến egress vì mọi record cũ/mới đều gọn hẳn.
- **Broadcast thay `postgres_changes`** cho tín hiệu "có gì đổi" (#3), giữ payload nhẹ; kết hợp với delta sync để không cần refetch toàn bộ khi có tín hiệu.
- **Soft-delete** (`deleted_at`) cho `gmp_records`/`gmp_submissions` để delta sync biết được các dòng đã xoá mà không cần full refetch để "phát hiện" việc thiếu dòng.
- **RPC gộp** (`gmp_save_records_batch`) để giảm số round-trip khi đồng bộ hàng loạt sau khi offline.
- Theo dõi định kỳ **Supabase Dashboard → Usage** (Egress theo Database/Storage/Realtime) sau mỗi lần triển khai để xác nhận cải thiện thực tế, vì các con số byte trong báo cáo này là ước lượng thô (không biết số dòng/kích thước ảnh thật trong DB hiện tại).

---
*Giả định đã dùng*: ~800 hạng mục checklist/kỳ, ảnh nén JPEG 1280px/quality 0.72 (~150-400KB trước base64), 15% dòng có ảnh, lịch sử tích lũy 6-12 tháng. Nên xác nhận lại bằng `select count(*) from gmp_records` và kích thước trung bình cột `images` trên Supabase Dashboard để có con số chính xác thay ước lượng.
