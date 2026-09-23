# HANDOFF — GMP Audit Checklist / GMP Score App

> Tài liệu bàn giao cho ai tiếp quản/chỉnh sửa app này sau này (người khác, chính bạn ở phiên khác, hoặc **một mô hình AI khác**). Cập nhật lần cuối: **2026-09-18**.
>
> ⚠️ **Đọc trước**: repo này giờ có **2 biến thể** của cùng 1 app. Mục 1-11 dưới đây mô tả bản **offline gốc** (`GMP_Score_App.html`, không đổi từ 2026-09-14). Nếu bạn cần tiếp tục công việc gần đây nhất (Supabase, đa thiết bị, đăng nhập, đồng bộ realtime, nhiều Auditor cùng chấm...), **nhảy thẳng xuống mục 12** — đó là biến thể đang được phát triển tích cực.

## 1. App này là gì

Một **file HTML duy nhất, chạy offline hoàn toàn** (`GMP_Score_App.html`, ~1.23MB, 1989 dòng) dùng để chấm điểm đánh giá GMP & 5S theo từng khu vực/Function nhà máy (ILD Coffee Vietnam), theo **kỳ tháng**. Không có build step, không server, không dependency ngoài — mở trực tiếp file `.html` bằng trình duyệt là chạy được. File này **cố tình giữ nguyên, không sửa** kể từ khi có bản Supabase (mục 12) — không upload file này lên GitHub vì có mật khẩu Admin nhúng cứng (xem mục 6).

Thư viện duy nhất được nhúng thẳng vào file (không CDN): **ExcelJS** (script đầu tiên trong `<script>`, dòng ~599 trở đi — 1 dòng minified rất dài, ~950K ký tự). Script chính (logic app) là `<script>` thứ hai, bắt đầu ngay sau khối ExcelJS.

## 2. Chạy & kiểm thử nhanh

Không cần build. Cách xem/test:

```bash
# Cách 1: mở trực tiếp file trong trình duyệt
# Cách 2: chạy static server (đã có sẵn cấu hình launch.json cho Browser pane của Claude Code)
python -m http.server 8791
```

`.claude/launch.json` trong thư mục này đã cấu hình sẵn config tên `gmp-static` (port 8791) để dùng với `preview_start` của Claude Code Browser pane.

**Kiểm tra cú pháp JS** (vì file có 1 dòng ExcelJS siêu dài, không đọc/edit trực tiếp bằng mắt được đoạn đó — xem mục 7):
```bash
node -e "
const fs = require('fs');
const html = fs.readFileSync('GMP_Score_App.html', 'utf8');
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)];
fs.writeFileSync('/tmp/_main.js', scripts[1][1]); // script thứ 2 = logic app
"
node --check /tmp/_main.js
```

**Kiểm thử chức năng**: dùng Browser pane (`preview_start name:"gmp-static"`), test qua UI hoặc gọi thẳng hàm JS qua `javascript_tool` (nhanh hơn click UI nhiều bước). Tài khoản test có sẵn trong `SEED_USERS` (xem mục 6) — đăng nhập `Admin` cần mật khẩu, đăng nhập bằng mã NV thường thì không cần mật khẩu.

⚠️ Khi test trên trình duyệt (kể cả Browser pane), nhớ dọn dữ liệu test trước khi kết thúc phiên để không để lại rác trong IndexedDB của origin đó:
```js
localStorage.clear();
indexedDB.deleteDatabase('gmp_score_db');
indexedDB.deleteDatabase('gmp_sync_db');
```

## 3. Kho dữ liệu (nguồn sự thật)

**IndexedDB** là kho chính (`gmp_score_db`, version **2**, mở qua `openDB()` ~dòng 720). 4 object store:

| Store | keyPath | Ý nghĩa |
|---|---|---|
| `records` | `id` | Mỗi dòng = **điểm 1 câu hỏi** của 1 Function trong 1 kỳ. `id = batch+"|"+i` (i = index câu hỏi). |
| `meta` | (key riêng) | Lưu các *file/directory handle* (File System Access): `csvHandle`, `exportDir`, `mediaDir`, `folderHandle` (đồng bộ). |
| `periods` | `id` | 1 dòng = 1 kỳ tháng. `id = "YYYY-MM"`. |
| `submissions` | `id` | 1 dòng = trạng thái nộp bài của 1 Function trong 1 kỳ. `id = period+"|"+code`. |

**localStorage** chỉ chứa cấu hình/dữ liệu nhỏ (không có ảnh):

| Key | Nội dung |
|---|---|
| `gmp_checklist_v1` | `CHK` — checklist hiện hành (có thể khác SEED gốc nếu đã Chỉnh sửa) |
| `gmp_capa_v1` | `CAPA` — hành động khắc phục, key `period+"||"+code+"||"+cat+"||"+req` |
| `gmp_settings_v1` | `SET` — cài đặt (công ty, ngưỡng điểm, `currentPeriod`, tabOrder…) |
| `gmp_users` | `USERS` — tài khoản đăng nhập |
| `gmp_records_backup_v1` | Bản mirror `RECORDS` **không kèm ảnh** (phòng hờ, không phải nguồn chính) |

**Ảnh bằng chứng**: base64 (`data:image/jpeg;base64,...`) nhúng thẳng trong `record.images[]` — nằm trong IndexedDB `records`, **không** bao giờ vào localStorage. Nếu người dùng đã chọn folder Mediasave (mục 5.4), mỗi ảnh còn được ghi thêm 1 bản file thật ra `Mediasave/YYYY-MM/` trên đĩa (không thay thế bản trong IndexedDB, chỉ là backup song song).

### Schema record (đại diện, xem `writeCurrentRows` ~dòng 1101)
```js
{
  id, batch,                 // batch = period+"|"+code (deterministic từ kỳ 09/2026)
  period,                    // "YYYY-MM"
  date, auditor,             // ngày chấm, tên người chấm
  code, full,                // mã Function, tên đầy đủ
  cat, req,                  // Chủ đề, Yêu cầu (từ checklist)
  score, cls,                // 2/1/0, nhãn phân loại (clsOf)
  finding, evidence,         // phát hiện, bằng chứng text
  images: [{name, data, createdAt, period, code, backupStatus, backupPath}]
}
```

### Schema period
```js
{ id:"2026-09", functions:[...mã Function lúc tạo kỳ], status:"Đang chấm"|"Đã chốt", createdAt, closedAt, closedBy }
```

### Schema submission
```js
{ id:"2026-09|M&I", period, code, status:"DRAFT"|"SUBMITTED"|"LOCKED", auditor, updatedAt, submittedAt, submittedBy, lockedAt, lockedBy }
```

## 4. Khái niệm cốt lõi cần hiểu trước khi sửa code

**Insight quan trọng nhất của kiến trúc này**: mọi hàm đọc điểm (`areaScore`, `latestByArea`, `capCountArea`, `allFindings`, `recordsForExport`…) khi **không truyền `period`** sẽ tự dùng `activePeriodId()` (kỳ đang mở, từ `SET.currentPeriod`). Nhờ vậy toàn bộ Thống kê / Tổng hợp QA / CAPA / Excel export / Mail **tự động chỉ thao tác trên kỳ đang mở**, không cần biết gì về khái niệm "kỳ" — chỉ tab **Lịch sử** truyền `period` tường minh để xem kỳ đã chốt cũ. Khi sửa code, **đừng phá insight này** — nếu thêm hàm đọc điểm mới, hãy để `period` là tham số optional mặc định `activePeriodId()`, đừng bắt buộc truyền.

**Vòng đời 1 Function trong 1 kỳ**: `DRAFT` (nháp, tự sửa được, `saveDraft()`) → `SUBMITTED` (`submitResult()`, người chấm hết quyền sửa, chỉ Admin sửa được qua `adminSaveEdit()`) → `LOCKED` (`lockFunction()` hoặc `lockWholePeriod()`, không ai sửa được nữa, kể cả Admin). Việc được sửa hay không do 2 hàm gác cổng: `functionLocked()` / `canEditFunction()` (~dòng 1726-1728) — **mọi đường ghi dữ liệu** (Chấm điểm, Lỗi nhanh, import Excel…) phải đi qua các hàm này trước khi `dbPut`.

**"Chốt toàn bộ kỳ"** (`lockWholePeriod`, ~dòng 1788) chặn nếu còn Function nào chưa ở trạng thái SUBMITTED/LOCKED — không cho chốt dở dang.

**Reset vs Tạo kỳ mới**: `resetActivePeriod()` chỉ xoá record/submission có đúng `period === activePeriodId()` (dùng `dbDel`, không bao giờ `dbClear()` toàn bộ) — kỳ khác không đụng tới, và chỉ chạy được khi kỳ hiện tại **chưa chốt**. `createNewPeriod()` không xoá/copy gì, chỉ tạo period row mới + đổi `SET.currentPeriod` — chỉ chạy được khi kỳ hiện tại **đã chốt**.

**Migration dữ liệu cũ** (`migrateToPeriods()`, ~dòng 1729, chạy 1 lần mỗi lần `boot()`): record nào chưa có `.period` sẽ được suy ra từ `record.date` (`inferPeriod`). Tháng trùng tháng hiện tại → kỳ "Đang chấm"; tháng khác → tự thành "Đã chốt" (lịch sử, không mất dữ liệu). Đây là lý do **không được xoá logic này** dù trông như "chỉ chạy 1 lần lúc đầu" — nó cũng là lưới an toàn nếu sau này có record nào lọt lưới thiếu `period`.

## 5. Các tab & phân quyền

Phân quyền tối giản 2 vai trò (không có hệ thống tài khoản phức tạp), dùng `CURRENT_USER`/`isAdmin()` (~dòng 1680):

- **Khách (chưa đăng nhập)** — vẫn xem/dùng được, không bị chặn màn hình đăng nhập (nút 🔐 Đăng nhập ở góc phải topbar mở popover nhỏ, không che nội dung).
- **User** (đăng nhập bằng Mã NV, không cần mật khẩu) — thêm quyền vào 3 tab `.guestTab`.
- **Admin** (`Admin`/`Admin2`, cần mật khẩu — xem `SEED_USERS` trong code, `grep -n "const SEED_USERS"`, không nhắc lại mật khẩu ở đây) — thêm quyền vào 4 tab `.adminTab` + các hành động Chốt/Tạo kỳ/Reset/Restore.

| Tab (`data-tab`) | Class ẩn/hiện | Ai dùng được |
|---|---|---|
| `input` (Chấm điểm) | — | Ai cũng vào được; sửa được hay không tuỳ `canEditFunction()` |
| `stats` (Thống kê) | — | Công khai |
| `capa` (CAPA) | — | Công khai |
| `sync` (Đồng bộ) | — | Công khai |
| `history` (Lịch sử) | — | Công khai, chỉ xem |
| `guide` (Hướng dẫn) | — | Công khai |
| `quick` (Lỗi nhanh) | `guestTab` | Cần đăng nhập (User/Admin) |
| `qa` (Tổng hợp QA) | `guestTab` | Cần đăng nhập |
| `approve` (Phê duyệt / Admin chốt điểm) | `guestTab` | Cần đăng nhập (nút Chốt/Tạo kỳ/Reset chỉ Admin) |
| `edit` (Chỉnh sửa checklist) | `adminTab` | Admin |
| `settings` (Cài đặt) | `adminTab` | Admin |
| `mail` (Mail) | `adminTab` | Admin |
| `users` (Tài khoản) | `adminTab` | Admin |

Ẩn/hiện tab xử lý trong `applyUserUI()` (~dòng 1663). Thứ tự tab hiển thị lấy từ `SET.tabOrder` (đổi được ở Cài đặt → 🔀 Thứ tự Tab), danh sách gốc là `DEFAULT_TAB_ORDER`/`TAB_LABELS` (~dòng 1910 khu vực gần đó — grep để tìm chính xác, xem mục 7).

## 6. Tài khoản mẫu

`SEED_USERS` (grep để xem, không chép lại ở đây vì có mật khẩu) là danh sách mặc định các nhân viên + 2 tài khoản Admin. Danh sách thật đang dùng nằm trong localStorage key `gmp_users` (Admin có thể sửa ở tab 👥 Tài khoản) — **không phải bảo mật mạnh**, mật khẩu nằm trong chính file HTML, chỉ đủ ngăn thao tác nhầm nội bộ.

## 7. Bản đồ code (grep theo tên hàm, đừng tin số dòng tuyệt đối)

⚠️ Số dòng dưới đây đúng tại thời điểm viết tài liệu này; **sẽ lệch** sau mỗi lần sửa file. Luôn dùng `grep -n "function tenHam"` để tìm vị trí thật.

```
Nền tảng chung       : $, esc, toast, clsOf, ratingOf, defSettings/loadSettings/saveSettings
Checklist             : loadChk/saveChk/seedChk, areaByCode, CHK, SEED (const khổng lồ ~dòng 649!)
CAPA                  : CAPA, capaKey(period,code,cat,req), loadCapa/saveCapa
IndexedDB helpers     : openDB, tx, dbAll/dbPut/dbDel/dbClear, metaGet/Put/Del,
                        perAll/perGet/perPut/perClear (periods), subAll/subGet/subPut/subDel/subClear (submissions)
Đọc điểm (period-aware): recordsForPeriodArea, latestByArea, areaScore, capCountArea, allFindings
CSV (tuỳ chọn)         : buildCsv/parseCsv, newFile/openFile/writeFile/unlinkCsv (chỉ còn ở tab Cài đặt, không bắt buộc)
Thư mục xuất Excel     : pickExportDir/clearExportDir/saveOut
Lỗi nhanh (tab quick)  : QK, qkAdd/qkSave/renderQkList/qkAreaChange
Chấm điểm (tab input)  : CURRENT, loadAreaForm, itemHtml, renderChecklist, bindChecklist,
                        writeCurrentRows/saveDraft/submitResult/adminSaveEdit, onKey, onPaste
Ảnh & Mediasave        : fileToImg (nén ảnh), attachImage (nén + backup),
                        pickMediaDir/clearMediaDir/backupImageToMedia/restoreMediaDir
Thống kê/Đồ thị        : drawStatChart, renderStats
Báo cáo Excel          : buildFullReportBlob (nút "Tải file tổng hợp" ở tab Thống kê, nhiều sheet màu),
                        buildWorkbookBlob (xuất theo khu vực/tổng hợp, dùng cho Mail & QA)
Tổng hợp QA            : renderQA
CAPA UI                : capaList/renderCAPA/exportCapaCsv/exportCapaXlsx
Import Excel           : parseWbRecords, importExcel (1 file), importExcelMulti (nhiều file, tab QA)
Mail (.eml)            : makeEml, mailSubject/mailBody, composeMail/sendAreaMail
Chỉnh sửa checklist    : renderEdit
Tài khoản/đăng nhập    : USERS, doLogin/doLogout, CURRENT_USER, isAdmin,
                        openLoginBox/closeLoginBox/toggleLoginBox (popover góc phải, không chặn app)
Đồng bộ nhiều máy      : syncDirHandle, writeSnapshot/mergeSnapshot/doSync/maybeAutoPush
KỲ CHẤM ĐIỂM (lõi mới) : PERIODS/SUBS, activePeriodId/activePeriod, subOf/setSubStatus,
                        functionLocked/functionSubmitted/canEditFunction,
                        migrateToPeriods, createNewPeriod, resetActivePeriod,
                        lockFunction, lockWholePeriod, renderApprove
Lịch sử (tab history)  : renderHistory/renderHistoryDetail/renderHistoryFuncDetail
Backup/Restore JSON    : backupJson/restoreJson (Cài đặt, chỉ Admin, có confirm trước khi ghi đè)
Điều hướng tab         : switchTab, renderAll, currentTabOrder/applyTabOrder/renderTabOrderSettings
Khởi động app          : boot() — cuối file, gọi openDB → seedIfEmpty → migrateToPeriods → render → gắn sự kiện
```

## 8. Gotcha khi thao tác trên file này

1. **Dòng SEED khổng lồ (~dòng 649)** chứa toàn bộ checklist 15 khu vực — đọc/chỉnh file bằng công cụ có giới hạn context (Read tool của Claude Code) sẽ lỗi "vượt quá token" nếu range đọc đè lên dòng này. Dùng `Grep -n -A/-B` để xem quanh khu vực đó thay vì `Read` với offset/limit rộng.
2. **ExcelJS nhúng là 1 dòng ~950K ký tự** (script đầu tiên) — không bao giờ đọc/sửa trực tiếp, chỉ script thứ 2 (logic app) mới cần đọc/sửa.
3. **`batch` là deterministic** (`period+"|"+code`) từ khi thêm mô hình Kỳ — 1 Function/1 kỳ chỉ có đúng 1 batch. Đừng quay lại kiểu `batch = date+"|"+Date.now()` (batch cũ trước khi có Kỳ) vì sẽ phá vỡ "mỗi Function/kỳ 1 kết quả duy nhất" và giả định upsert-by-id ở khắp nơi.
4. **`parseWbRecords`** (import Excel) tự suy `period` từ cột Ngày của từng dòng qua `inferPeriod` — nếu sửa phần import, giữ nguyên field `period` này, nếu không dữ liệu import sẽ "rơi" nhầm kỳ khi đọc lại.
5. Khi thêm **hành động phá huỷ dữ liệu mới** (kiểu Reset), luôn: (a) gate bằng `isAdmin()`, (b) có `confirm()` mô tả rõ phạm vi ảnh hưởng, (c) xoá đúng scope (period cụ thể), không bao giờ gọi `dbClear()` trừ khi thực sự muốn xoá sạch mọi kỳ (xem `clearAllData` — nút "Xoá toàn bộ dữ liệu đã chấm" ở Cài đặt là trường hợp cố ý xoá sạch mọi kỳ, có cảnh báo rõ).
6. **File System Access API** (chọn thư mục CSV/Excel/Mediasave/Đồng bộ) chỉ chạy trên **Chrome/Edge desktop**. Mọi nơi dùng nó đều phải có fallback không throw lỗi (xem `backupImageToMedia`, `saveOut`) — giữ nguyên pattern này khi thêm tính năng tương tự.
7. Sau bất kỳ sửa đổi JS nào, luôn `node --check` script thứ 2 trước khi coi là xong (xem mục 2) — file lớn, lỗi cú pháp dễ lọt qua mắt thường.

## 9. Giới hạn đã biết

- File System Access (thư mục CSV/Excel/Mediasave/Đồng bộ) không chạy trên Safari, Firefox, hay trình duyệt di động — các tính năng liên quan tự động fallback về "tải file về" hoặc báo không hỗ trợ, không chặn luồng chính (chấm điểm/nháp/gửi/chốt luôn hoạt động vì dựa trên IndexedDB).
- Không có xác thực mạnh — mật khẩu Admin nằm trong chính file HTML (xem mục 6).
- Đồng bộ nhiều máy qua thư mục dùng chung không phải real-time — cần bấm "Đồng bộ" thủ công và chờ OneDrive/Drive đồng bộ file xong.
- Chưa hỗ trợ mở lại kỳ đã chốt, phân quyền nhiều cấp, so sánh điểm giữa các tháng, audit log chi tiết, hay đồng bộ cloud thật sự — các mục này được đánh dấu **Optional/bỏ qua** trong lần nâng cấp mô hình Kỳ (2026-09) để giữ app đơn giản; làm thêm nếu có yêu cầu cụ thể sau này.

## 10. Lịch sử thay đổi (tóm tắt các đợt nâng cấp gần đây)

1. Nút "Nạp nhiều file Excel Chấm điểm" ở tab Tổng hợp QA (`importExcelMulti`, tự nhận diện khu vực theo cột "Mã khu vực").
2. Tab Phê duyệt: nút Reset kỳ + tháng đánh giá (phiên bản đầu, sau đó được thay bằng mô hình Kỳ đầy đủ ở bước 6).
3. Nút "Tải CSV" ở tab Thống kê đổi thành "Tải file tổng hợp (Excel)" — `buildFullReportBlob`, nhiều sheet màu (Tổng hợp/CAPA/từng khu vực).
4. Tên file báo cáo theo tháng người dùng chọn: `GMP Score MM.YYYY.xlsx`.
5. Bỏ rào cản đăng nhập bắt buộc — khách vào dùng được ngay, đăng nhập chuyển thành popover góc phải không chặn màn hình.
6. Mặc định khách chỉ thấy 5 tab công khai; ô "Người đánh giá" có dropdown gợi ý tên từ danh sách tài khoản; đổi tiêu đề app thành "GMP Audit Checklist - GMP Score".
7. **Nâng cấp lớn**: mô hình Kỳ chấm điểm theo tháng + DRAFT/SUBMITTED/LOCKED + Admin chốt điểm + tab Lịch sử + Tạo kỳ mới/Reset kỳ đang chấm (thay nút Reset cũ) + backup ảnh ra folder Mediasave + IndexedDB làm kho chính (bỏ banner/chip nhắc CSV khỏi luồng hằng ngày) + Backup/Restore JSON có xác nhận & gate Admin. Đây là thay đổi kiến trúc lớn nhất — xem chi tiết mục 3-5 ở trên.
8. File `HANDOFF.md` này được tạo (2026-09-14).

## 11. Việc còn để ngỏ / gợi ý cho lần sau

- Guide trong app (tab 📖 Hướng dẫn) đã cập nhật phần A/B/C cho mô hình Kỳ mới; các mục D-K còn theo văn phong cũ, có thể rà lại nếu muốn đồng bộ thuật ngữ hoàn toàn.
- Chưa có cách "mở lại" 1 kỳ đã chốt nếu chốt nhầm (cố ý bỏ qua theo yêu cầu ban đầu — nếu cần, thêm 1 hành động Admin riêng, có audit log ai/khi nào mở lại).
- `clearAllData` (Xoá toàn bộ dữ liệu đã chấm) vẫn xoá sạch mọi kỳ kể cả đã chốt — cân nhắc bỏ hẳn nút này hoặc giới hạn phạm vi nếu thấy rủi ro thao tác nhầm quá cao trong thực tế sử dụng.

---

## 12. Bản Supabase đa thiết bị — `ready/index.html`

> Biến thể **đang phát triển tích cực** (2026-09-16 → 2026-09-18), chuyển từ bản offline ở mục 1-11 sang lưu trữ đa thiết bị qua Supabase + publish qua GitHub Pages. Đọc mục này **thay vì** mục 1-11 nếu bạn tiếp tục công việc gần đây nhất. Tài liệu song song: **`README - GMP Score Supabase.md`** (hướng dẫn cài đặt Supabase/GitHub từng bước cho người vận hành) — mục 12 này là tài liệu **kỹ thuật/kiến trúc** cho người sửa code.

### 12.1. Quan hệ với bản offline

`ready/index.html` (2317 dòng) là bản **chuyển thể** từ `GMP_Score_App.html`, KHÔNG phải file khác biệt hoàn toàn — cùng toàn bộ logic chấm điểm/checklist/CAPA/Excel/Mail ở mục 1-11 vẫn còn nguyên (đọc mục 1-11 để hiểu phần đó, không lặp lại ở đây). Điểm khác biệt cốt lõi: **nơi lưu trữ** (IndexedDB cục bộ → đồng bộ 2 chiều với Supabase) và **nguồn xác thực** (Mã NV cục bộ không mật khẩu → phiên ẩn danh Supabase + RPC xác thực, Admin cục bộ → tài khoản Supabase Auth thật).

Thư mục `ready/` là **thứ duy nhất được publish lên GitHub Pages** (xem README mục 2) — không publish `GMP_Score_App.html`/`HANDOFF.md` gốc.

```
ready/
  index.html          — app (chuyển thể từ GMP_Score_App.html)
  config.js            — SUPABASE_URL/anonKey (đã điền thật — xem mục 12.11 cảnh báo)
  vendor/supabase.js    — supabase-js v2 UMD, host offline (không CDN)
supabase/
  schema.sql            — toàn bộ bảng/RLS/RPC (chạy 1 lần trong SQL Editor, an toàn chạy lại)
  functions/admin-users/index.ts — Edge Function quản lý tài khoản Admin (service_role)
README - GMP Score Supabase.md  — hướng dẫn cài đặt cho người vận hành (không phải tài liệu kỹ thuật)
```

> ⚠️ **Repo này (`C:\Users\BinhDang\Documents\GitHub\GMP-Score`, remote `github.com/ngocthanhthien/GMP-Score`) KHÔNG theo đúng cây thư mục trên** — đây là bản đã publish, dẹt ở gốc: `index.html`/`config.js`/`vendor/supabase.js` nằm thẳng ở root (không có thư mục `ready/`). **Cập nhật 2026-09-23**: `supabase/schema.sql` và `supabase/functions/admin-users/index.ts` **đã được copy vào repo này** (nguồn tại `C:\Apps\GMP_Score_App` vẫn còn, coi là bản lưu trữ cũ — sửa server-side thì sửa ở repo này, KHÔNG sửa bản ở `C:\Apps\GMP_Score_App` nữa để tránh lệch lại). `GMP_Score_App.html` và `README - GMP Score Supabase.md` (bản offline gốc + doc hướng dẫn cài đặt) vẫn CHỈ tồn tại ở `C:\Apps\GMP_Score_App`, chưa đưa vào repo này (không bắt buộc — `GMP_Score_App.html` không publish). Repo này còn có `EGRESS_AUDIT.md` (audit + lịch sử fix hiệu năng/egress, đọc trước khi sửa bất cứ gì liên quan tới đồng bộ/ảnh — xem 12.5) và `supabase/add_updated_at.sql` (chỉ dùng để retrofit project CŨ đã chạy schema.sql trước khi có mục 8b — project mới không cần chạy file này, xem ghi chú đầu file đó).
>
> **Project Supabase đang trỏ tới (2026-09-23)**: đã đổi sang project mới **"GMP Score App"** (`https://mnhlddcvbzihhnnirhiz.supabase.co`, `config.js` đã cập nhật anon key mới) — project cũ `thhevdrgbxvyatfvtyrh.supabase.co` không còn dùng. Project mới **chưa chạy schema.sql / chưa deploy Edge Function / chưa bật anonymous sign-in / chưa tạo Admin** — xem checklist việc-cần-làm-tay ở 12.11.

### 12.2. Chạy & kiểm thử nhanh

Giống mục 2 (script thứ 2 trong `<script>` mới cần đọc/sửa, tránh dòng SEED/ExcelJS khổng lồ), nhưng phục vụ trực tiếp thư mục `ready/`:

```bash
cd ready && python -m http.server 8791
```

⚠️ **Không test trực tiếp trên `ready/config.js` hiện tại nếu chỉ muốn kiểm tra UI/logic** — file đó đã có `SUPABASE_URL`/`anonKey` **thật** của project đang dùng thật (xem mục 12.11). Test UI/logic không cần dữ liệu thật thì copy `ready/` ra thư mục tạm, thay `config.js` bằng URL giả (`https://YOUR_PROJECT_REF.supabase.co`) để `sbConfigured()` trả `false` (an toàn, không gọi mạng) — hoặc dùng URL "trông thật nhưng không tồn tại" (VD `https://fake-test.supabase.co`) + tự gán `SESSION_READY=true` và monkey-patch `SB.from`/`SB.auth`/`SB.rpc` qua `javascript_tool` nếu cần chạy thử `pullAll()`/`pushOne()` thật (đã dùng cách này để bắt lỗi thật trong mục 12.7 — xem lịch sử hội thoại lúc sửa bug đó nếu cần tái tạo).

Kiểm tra cú pháp JS — script thứ 2 (không phải thứ nhất, đó là ExcelJS):
```bash
node -e "
const fs = require('fs');
const html = fs.readFileSync('ready/index.html', 'utf8');
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)];
fs.writeFileSync('_check.js', scripts[scripts.length-1][1]);
"
node --check _check.js && rm _check.js
```

### 12.3. Kho dữ liệu: local (không đổi) + Supabase (mới)

**Local vẫn là IndexedDB `gmp_score_db`, nhưng version 3** (thêm 1 store so với mục 3): store `pending` mới — hàng đợi bản chờ, xem 12.5. Toàn bộ schema record/period/submission ở mục 3 **vẫn đúng**, chỉ thêm field `submitterKey` vào record và submission (xem 12.6).

**Supabase** (`supabase/schema.sql`) — mọi bảng tiền tố `gmp_`, RLS bật hết, ghi dữ liệu chỉ qua RPC (không có policy insert/update/delete trực tiếp cho `authenticated`):

| Bảng | Ứng với local | Ghi chú |
|---|---|---|
| `gmp_members` | (mới, không có ở bản offline) | Tài khoản Admin thật. RLS SELECT **hẹp**: chỉ đúng dòng mình hoặc admin (không dùng `gmp_is_member()` — bảng này chứa email, nhạy cảm hơn các bảng khác). |
| `gmp_auditors` | (mới) | Danh sách tên+Mã NV (tầng User không cần tài khoản), 1 dòng JSONB `id='current'`. RLS SELECT **admin-only** — client thường lấy tên qua RPC `gmp_list_auditor_names()` (không kèm mã). |
| `gmp_periods` | store `periods` | Không đổi cấu trúc, thêm không có field mới đáng kể. |
| `gmp_submissions` | store `submissions` | **Có thay đổi lớn**: thêm cột `submitter_key`/`submitter_name`/`final_submitter` — 1 dòng có thể là bản CHÍNH THỨC (`submitter_key is null`, id=`period\|code`) hoặc bài CÁ NHÂN của 1 Auditor (id=`period\|code\|submitterKey`). Xem 12.6. |
| `gmp_records` | store `records` | Cột `full_name`/`updated_by` chỉ có ở server (không map ngược về local); `submitter_key` map 2 chiều. |
| `gmp_capa`, `gmp_checklist`, `gmp_settings` | `CAPA`/`CHK`/`SET` (localStorage) | Mỗi bảng 1 dòng JSONB `id='current'` chứa nguyên khối — không tách quan hệ, đơn giản và đủ dùng vì ít khi 2 người sửa đồng thời. |
| `gmp_audit_log` | (mới) | Server tự ghi mọi RPC ghi dữ liệu (actor, action, detail) — chỉ Admin đọc được. |

RPC quan trọng nhất (đọc `gmp_save_record`/`gmp_set_submission` trong `schema.sql` trước khi sửa bất cứ gì liên quan tới ghi điểm — 2 hàm này chứa TOÀN BỘ luật khoá/quyền phía server, xem 12.6):

```
gmp_save_record(p jsonb)                — ghi 1 dòng điểm, tự phân biệt bản chính thức/cá nhân qua p->>'submitterKey'
gmp_delete_record(p_id text)
gmp_set_submission(p_period,p_code,p_status,p_auditor,p_submitter_key,p_submitter_name,p_final_submitter)
gmp_create_period / gmp_reset_period / gmp_lock_whole_period(p_period)
gmp_purge_finalized_candidates(p_period)  — dọn bài cá nhân của khu vực ĐÃ CHỐT, admin-only, thủ công
gmp_save_capa / gmp_save_checklist / gmp_save_settings / gmp_save_auditors (p_data jsonb)
gmp_list_auditor_names()                — chỉ trả TÊN, không trả Mã NV
gmp_verify_auditor_code(p_name,p_code)  — chỉ trả true/false, không trả Mã NV
gmp_is_member() / gmp_is_admin() / gmp_display_name()  — helper SECURITY DEFINER dùng chung mọi nơi
```

### 12.4. Mô hình đăng nhập (đã đổi 3 lần trong quá trình làm — đây là bản CUỐI)

Rào cản đăng nhập **bắt buộc** (`setGate(true)` lúc `boot()`, xem `#loginOverlay.gate` trong CSS) — không có nút ✕/Esc/click-ra-ngoài để bỏ qua. Có 2 cách qua được:

1. **Tầng User** (không cần tài khoản Supabase Auth thật): chọn tên trong dropdown (`AUDITOR_NAMES`, lấy qua RPC `gmp_list_auditor_names()` — không kèm mã) + nhập **Mã NV**, xác thực qua RPC `gmp_verify_auditor_code()` (chỉ trả đúng/sai). Phía dưới, mọi phiên (kể cả trước khi chọn tên) đã có sẵn 1 **phiên ẩn danh Supabase** (`SB.auth.signInAnonymously()`, gọi trong `ensureSession()`) — cần bật **"Allow anonymous sign-ins"** trong Supabase Dashboard, KHÔNG bật mặc định trên project mới (nếu quên bước này, `ensureSession()` báo lỗi rõ ràng trong `#loginErr` chứ không treo im lặng).
2. **Tầng Admin**: `SB.auth.signInWithPassword()` chuẩn, kiểm tra có dòng trong `gmp_members` với `role='admin'` và `disabled=false`. Tạo/quản lý tài khoản Admin qua Edge Function `admin-users` (mục 12.3 file map + README mục 5) — KHÔNG tạo trực tiếp trong code.

⚠️ **Giới hạn bảo mật phải nhớ và nói rõ nếu ai hỏi**: bước xác thực Mã NV chỉ chặn ở **giao diện**. Phiên ẩn danh phía dưới đã có `auth.uid()` hợp lệ và đã qua được RLS (`gmp_is_member()` = "có phiên là được", áp dụng cho hầu hết bảng dữ liệu nghiệp vụ) **trước khi** người dùng nhập Mã NV — ai mở Console gọi thẳng `SB.from(...)`/`SB.rpc(...)` vẫn đọc/ghi được mà không cần qua đúng Mã NV. Đây là lựa chọn có chủ đích cho công cụ nội bộ (xem README mục 4), không phải sơ suất — nhưng đừng vô tình nói với người dùng rằng đây là bảo mật thật sự.

Hàm liên quan: `ensureSession`, `doPickAuditor`, `doLogin`, `afterSignIn`, `doLogout`, `setGate`, `applyUserUI`, `isAdmin` — tất cả ở khu vực dòng 1697-1820 (grep để tìm chính xác).

**Phân quyền tab đã siết lại đáng kể** so với bản offline (mục 5): tài khoản **User** giờ **chỉ** thấy 2 tab `input` (Chấm điểm) và `guide` (Hướng dẫn). Mọi tab khác đều mang class `.adminTab` (kể cả `stats`/`capa`/`sync`/`history` vốn công khai ở bản offline). Tab **`quick` (Lỗi nhanh) đã bị xoá hoàn toàn** khỏi bản này (không chỉ ẩn — xoá markup + toàn bộ hàm `qk*`/biến `QK`, xoá khỏi `DEFAULT_TAB_ORDER`/`TAB_LABELS`) — đừng ngạc nhiên nếu thấy nhắc tới "Lỗi nhanh" ở mục 1-11, tab đó không còn ở bản này.

### 12.5. Mô hình đồng bộ

> ⚠️ **Đã nâng cấp đáng kể sau 2 đợt audit Egress** (`EGRESS_AUDIT.md` trong repo này, 2026-09-20 và 2026-09-23) — đọc file đó để có chi tiết/số liệu test trước khi sửa bất cứ gì ở mục này. Tóm tắt kiến trúc HIỆN TẠI (không phải bản gốc lúc mới viết mục 12):

Triết lý: **IndexedDB cục bộ vẫn là nguồn cho UI** (như mục 3-4), chỉ phủ thêm 1 lớp mỏng — xem chi tiết kèm code mẫu tổng quát hoá (bản gốc, chưa có các tối ưu egress bên dưới) trong skill `supabase-sync-auth-patterns` (đã đóng gói riêng, xem 12.11) nếu cần áp dụng cho app khác.

- **`installSyncWraps()`** (gọi 1 lần trong `boot()`, **sau** `seedIfEmpty()` — thứ tự này quan trọng, nếu lắp trước sẽ đẩy nhầm dữ liệu SEED demo lên server thật) — bọc lại `dbPut`/`dbDel`/`saveCapa`/`saveChk`/`saveSettings`/`saveAuditors`, giữ nguyên mọi nơi gọi cũ.
- **Hàng đợi bản chờ**: store `pending` (IndexedDB), key `kind+":"+id`, debounce 1.5s (`scheduleFlush`/`flushPending`/`pushOne`). `flushPending` gửi **song song theo lô 5** (không còn tuần tự từng item).
- **`pullTables(tables, silent, force)`** (KHÔNG phải `pullAll` kéo cả 7 bảng như thiết kế ban đầu) — chỉ kéo đúng các bảng trong `tables`; với `gmp_records`/`gmp_periods`/`gmp_submissions`, nếu `force=false` sẽ dùng **delta-sync thật** theo cột `updated_at` (`fetchTableRows`, tự fallback full-select nếu cột chưa tồn tại — xem `supabase/add_updated_at.sql`, mục 12.11 nhắc lại việc cần chạy file này). `pullAll(silent)` giờ chỉ là alias gọi `pullTables(ALL_SYNC_TABLES,silent,true)` — LUÔN kiểm tra hàng đợi trước khi ghi đè 1 id cục bộ, dùng cho lúc boot/đăng nhập/đăng xuất (cần đảm bảo full state đúng mỗi phiên mới).
- **Realtime**: `startRealtime()`/`scheduleRealtimePull(table)` — subscribe `postgres_changes` trên 7 bảng, debounce 400ms rồi gọi `pullTables()` **chỉ với (các) bảng thực sự vừa đổi** (không phải luôn cả 7 bảng). Bật Realtime phía server qua khối `do $$ ... alter publication supabase_realtime add table ...` cuối `schema.sql` gốc (an toàn chạy lại).
- **Poller** (`startPoller`) — dừng hẳn khi `document.hidden` (tab nền không tốn egress); khi Realtime đang SUBSCRIBED, giãn ra ~2 phút/lần thay vì 30s (chỉ còn là lưới an toàn); cứ ~20 lượt tự full-select 1 lần để tự phục hồi nếu delta lệch.
- **`visibilitychange`** (quay lại tab) — gọi `pullTables(ALL_SYNC_TABLES,true,false)` (**`force=false`**, dùng delta — KHÔNG dùng `pullAll(true)`/force=true, đó chính là lỗi egress lớn nhất tìm thấy ở đợt audit 2026-09-23, đã sửa).
- **Ảnh**: `attachImage` upload lên Storage đúng **bản đã nén cục bộ** (`dataUrlToBlob(im.data)`, canvas 1280px/q0.72), KHÔNG upload file gốc (sửa ở đợt audit 2026-09-23 — trước đó vô tình upload nguyên file gốc, có thể vài-chục MB/ảnh). Hiển thị qua `resolveImgUrl` (signed URL, cache theo TTL trong `imgUrlCache`). Xuất Excel dùng `imgRawB64(im)` (tự tải từ Storage nếu ảnh chỉ có `.path`) ở **cả 3** chỗ xuất ảnh (`buildWorkbookBlob`/`buildFullReportBlob`/`exportCapaXlsx` — chỗ thứ 3 từng bị bỏ sót, đã vá).
- Chip ☁️ góc trên phải (`updateCloudChip`) hiện "⚡ Realtime" khi kênh SUBSCRIBED, ngược lại hiện trạng thái hàng đợi/polling.

### 12.6. Nhiều Auditor cùng chấm 1 khu vực — Admin chọn kết quả cuối cùng

Thay đổi lớn nhất so với mục 4 (vòng đời DRAFT→SUBMITTED→LOCKED vẫn giữ nguyên Ý TƯỞNG, nhưng thêm 1 lớp phía trước nó):

- **Batch chính thức** (`period+"|"+code`, đúng như mục 4/mục 8.3) — đây vẫn là dữ liệu duy nhất mà `areaScore`/`latestByArea`/CAPA/Excel/Thống kê/Lịch sử đọc. **Không đổi các hàm đọc này.**
- **Batch cá nhân** (`period+"|"+code+"|"+submitterKey`, `submitterKey = safeName(CURRENT_USER.code||CURRENT_USER.name)`) — User (không phải Admin) lưu vào đây khi dùng tab Chấm điểm (`writeCurrentRows` tự tách nhánh theo `isAdmin()`). Nhiều Auditor có thể có nhiều batch cá nhân song song cho cùng 1 Function/kỳ, không ai ghi đè ai. Mỗi Auditor chỉ thấy **bài của chính mình** (`loadAreaForm` tự tính `submitterKey` từ `CURRENT_USER`).
- Admin xem tất cả bài cá nhân ở tab Phê duyệt → card "📝 Bài chấm đang chờ duyệt" (`renderCandidateReview`) → "👁️ Xem" (mở `loadAreaForm(code, submitterKey)` ở chế độ **chỉ đọc**, `CURRENT.preview=true`) → "✅ Chọn làm kết quả cuối cùng" (`promoteCandidate`) copy dữ liệu bài đó sang batch chính thức + set submission chính thức `SUBMITTED` với `finalSubmitter` ghi lại **ai** được chọn. Từ đây Admin sửa tiếp bằng chính tab Chấm điểm bình thường (`adminSaveEdit`, không cần màn hình riêng) rồi 🔒 Chốt như cũ.
- **`purgeFinalizedCandidates()`** (nút "🗑️ Dọn dữ liệu chấm cá nhân" ở tab Phê duyệt, admin-only, thủ công) — xoá mọi batch cá nhân thuộc Function **đã LOCKED** trong kỳ đang mở, không đụng batch chính thức, không đụng Function chưa chốt. Chỉ áp dụng cho kỳ đang mở — kỳ cũ đã chốt hẳn phải dọn tay qua SQL (`select gmp_purge_finalized_candidates('YYYY-MM')`).

### 12.7. Bẫy đã gặp thật khi làm mục 12 — đọc trước khi thêm form "sửa nháp rồi Lưu"

**Đây là bug thật đã xảy ra và được user report, không phải rủi ro lý thuyết** — nếu bạn (AI hay người) định thêm bất kỳ form kiểu "sửa thoải mái, bấm Lưu mới ghi" (giống `renderEdit`/checklist, xem 12.8), PHẢI làm đúng pattern dưới, nếu không sẽ tái diễn lỗi y hệt.

Diễn biến lỗi thật: khi thêm nút 💾 Lưu cho tab Chỉnh sửa checklist (đổi từ auto-save mỗi lần gõ sang "sửa nháp, bấm Lưu mới ghi"), quên rằng `pullAll()` (đặc biệt do Realtime kích hoạt — chạy mỗi khi **BẤT KỲ AI sửa BẤT KỲ THỨ GÌ**, kể cả một điểm chấm không liên quan) sẽ nạp lại `CHK` từ server bất cứ lúc nào, **xoá sạch nháp đang gõ dở** vì hàng đợi (12.5) chỉ bảo vệ dữ liệu **từ lúc `enqueueSync` được gọi** — mà nháp chưa bấm Lưu thì chưa hề gọi `enqueueSync`.

**Cách đã sửa** (đọc `updateChkSaveBtn`/`markChkDirty`/`saveChkChanges` dòng ~1514-1516, và điều kiện `&&!chkDirty` trong nhánh checklist của `pullAll` dòng ~1890 khu vực đó): mỗi form "nháp riêng" cần 1 cờ dirty CỦA RIÊNG NÓ, bật lúc bắt đầu sửa, tắt lúc Lưu thành công; nhánh tương ứng trong `pullAll()` phải thêm điều kiện `&& !cờ_đó` trước khi ghi đè. Đã verify bằng cách monkey-patch `SB.from()` để giả lập server trả dữ liệu khác trong lúc `chkDirty=true` — xác nhận không bị ghi đè; sau khi `chkDirty=false`, pull tiếp theo mới nhận dữ liệu mới.

### 12.8. Bản đồ code bổ sung (chỉ phần MỚI so với mục 7 — mục 7 vẫn đúng cho phần logic chấm điểm/Excel/Mail không đổi)

⚠️ Số dòng đúng tại thời điểm viết (2026-09-18), sẽ lệch sau mỗi lần sửa — luôn `grep -n "function tenHam"` để tìm vị trí thật.

```
Đăng nhập/phiên (12.4)     : renderAuditorSelect/loadAuditorNames/doPickAuditor (~1700-1730),
                             doLogin/afterSignIn/doLogout (~1733-1770),
                             isLoginBoxOpen/openLoginBox/closeLoginBox/toggleLoginBox/setGate (~1770-1774),
                             applyUserUI/isAdmin (~1775-1785)
Supabase client & phiên     : SB/sbConfigured/SESSION_READY/ensureSession/initCloud (~1788-1830)
Edge Function (12.3)        : edgeUrl/callAdminUsers (~1830-1838)
Hàng đợi & đồng bộ (12.5)   : pendKey/enqueueSync/scheduleFlush/updateCloudChip/flushPending/pushOne (~1839-1886)
Map local<->server           : mapServerRecord/mapServerPeriod/mapServerSub (~1887-1889)
Kéo dữ liệu (12.5/12.7)     : pullAll (~1890-1917), startPoller/doSync/maybeAutoPush (~1918-1920)
Realtime (12.5)             : scheduleRealtimePull/startRealtime/stopRealtime (~1925-1946)
Sync-shim (12.5)            : installSyncWraps (~1947-1956)
Kỳ & submission (đã đổi)    : subKey/subOf/candidatesForFunction/setSubStatus (~1964-1978, thêm submitterKey),
                             functionLocked/functionSubmitted/canEditFunction (~1979-1981, thêm submitterKey)
Nhiều Auditor (12.6)        : loadAreaForm(code,previewKey)/myAuditorKey (~862-883),
                             writeCurrentRows (~1077, tách nhánh admin/candidate),
                             renderApprove/renderCandidateReview/promoteCandidate/purgeFinalizedCandidates (~2059-2163)
Discard (mới)                : discardCurrentEdit (~1111), nút trong footButtonsHtml (~900)
Checklist sửa-nháp (12.7)    : chkDirty/updateChkSaveBtn/markChkDirty/saveChkChanges (~1514-1516), renderEdit (~1517)
Danh sách người đánh giá      : AUDITORS/loadAuditors/saveAuditors (~708-710), renderAuditorsAdmin (~1587),
Excel người đánh giá          : buildAuditorsWorkbookBlob/exportAuditorsXlsx/exportAuditorsTemplate/importAuditorsXlsx (~1599-1640)
Quản lý tài khoản Admin (UI) : renderUsers/addUserPrompt (~1543-1586, gọi Edge Function, KHÔNG thao tác localStorage nữa)
Ảnh: upload bản gốc          : uploadImageToStorage (~1055, gọi song song attachImage, không chặn luồng lưu chính)
```

### 12.9. Giới hạn đã biết (bổ sung mục 9)

- RLS "có phiên là đọc được" cho hầu hết bảng dữ liệu nghiệp vụ — rào cản giao diện, không phải chặn thật (xem 12.4 cảnh báo bảo mật, và README mục 4/4b).
- `gmp_purge_finalized_candidates` chỉ thao tác trên kỳ **đang mở** — kỳ cũ đã chốt hẳn phải dọn tay qua SQL.
- **Chưa test Realtime thật** — mọi test trong quá trình làm mục 12 đều qua bản sao cách ly (config giả hoặc mock `SB`), chưa từng kết nối `SUBSCRIBED` thật với project Supabase thật. Nếu chip ☁️ không bao giờ hiện "⚡ Realtime" sau khi làm đúng mục 12.11, kiểm tra: đã chạy lại `schema.sql` mới nhất chưa (bảng chưa nằm trong publication), tường lửa mạng có chặn `wss://` không.
- Excel import (`importExcel`/`importExcelMulti`, mục 7) vẫn ghi thẳng vào batch tự suy từ file, **không đi qua** lớp candidate ở 12.6 — dữ liệu import coi như "chính thức" ngay, không qua bước Admin duyệt. Có chủ đích (import là để đưa dữ liệu cũ vào, không phải luồng chấm sống) nhưng cần biết nếu có ai hỏi vì sao import không hiện ở "Bài chấm đang chờ duyệt".

### 12.10. Lịch sử thay đổi (biến thể Supabase, 2026-09-16 → 2026-09-18)

1. Khởi tạo `ready/` + `supabase/schema.sql` + Edge Function `admin-users` — mô hình ban đầu: online-required, mọi tài khoản (kể cả User) đăng nhập Email/mật khẩu Supabase Auth thật.
2. Đổi lại: bỏ rào cản cho tầng User — phiên ẩn danh tự động + popover chọn tên không mật khẩu, Admin vẫn email/mật khẩu thật. Thêm tab Quản lý người dùng (Edge Function) + danh sách người đánh giá (Excel export/template/import).
3. Popover chọn tên tự hiện ngay khi mở app thay vì phải bấm nút.
4. Đổi lại lần nữa (bản cuối, mục 12.4): khôi phục rào cản bắt buộc, nhưng dùng Mã NV xác thực qua RPC thay vì mật khẩu Supabase Auth đầy đủ cho tầng User.
5. Siết phân quyền tab: User chỉ còn thấy Chấm điểm + Hướng dẫn; xoá hẳn tab Lỗi nhanh.
6. Thêm nút 💾 Lưu cho tab Chỉnh sửa checklist (chuyển từ auto-save sang sửa-nháp-rồi-Lưu) + nút ▲▼ sắp xếp thứ tự câu hỏi.
7. Thêm đồng bộ Realtime (thay vì chỉ polling 30s) — phát hiện và sửa bug dirty-flag thật ở bước 6 (xem 12.7). Tiện thể sửa 1 bug có sẵn: `doLogout()` quên khởi động lại polling sau khi Admin đăng xuất.
8. Thêm nút ↩️ Discard ở tab Chấm điểm — huỷ thay đổi chưa lưu, tải lại bản đã lưu gần nhất.
9. **Nâng cấp lớn**: nhiều Auditor cùng chấm 1 khu vực + Admin chọn kết quả cuối cùng (mục 12.6) — thêm lớp batch cá nhân song song với batch chính thức, tab Phê duyệt có card duyệt bài, nút dọn dữ liệu cá nhân.
10. Đóng gói kiến trúc mục 12.4/12.5 thành 1 Claude Skill dùng lại được — `supabase-sync-auth-patterns` (không nằm trong repo này, là skill riêng đã gửi cho người dùng dưới dạng file `.skill`) — tham khảo nếu cần áp dụng đúng pattern này cho 1 app khác.
11. Mục 12 này được viết vào `HANDOFF.md` (2026-09-18).
12. **Repo chuyển sang Git thật** (`github.com/ngocthanhthien/GMP-Score`, layout dẹt ở root — xem cảnh báo đầu mục 12) — tiếp tục ở phiên/máy khác, publish GitHub Pages thật.
13. **Audit Egress lần 1** (2026-09-20, `EGRESS_AUDIT.md`) — phát hiện `pullAll()` full-table 7 bảng mọi lúc là nguồn egress lớn nhất (có thể 150-500+MB/lượt khi dữ liệu lớn). Sửa: tách `pullTables(tables,silent,force)` (Realtime chỉ kéo đúng bảng đổi), delta-sync theo `updated_at`, ảnh mới chỉ lưu `path` Storage thay vì base64 trong DB. Thêm `supabase/add_updated_at.sql`.
14. **Audit Egress lần 2** (2026-09-23) — audit độc lập, không dựa báo cáo lần 1. Phát hiện: (a) `visibilitychange` vẫn gọi `pullAll(true)` ép full-select, xoá sạch lợi ích delta-sync ở bước 13 mỗi lần đổi tab; (b) ảnh Storage đang lưu **file gốc chưa nén** (không phải bản đã nén canvas) — tiềm năng tốn hơn cả base64 cũ; (c) `exportCapaXlsx()` bị bỏ sót khi sửa ảnh ở bước 13, ảnh biến mất khỏi Excel CAPA; (d) `flushPending()` vẫn gửi tuần tự. Cả 4 đã sửa, test bằng monkey-patch `SB` (xem `EGRESS_AUDIT.md` mục 0b).
15. **Chuyển sang project Supabase mới** (2026-09-23) — project "GMP Score App" (`mnhlddcvbzihhnnirhiz.supabase.co`), Admin dự kiến `binh.dang@ild-coffee.com`. Copy `schema.sql` (đã merge sẵn mục 8b updated_at/trigger) + `functions/admin-users/index.ts` từ `C:\Apps\GMP_Score_App` vào repo này lần đầu; cập nhật `config.js` sang url/anonKey mới. Project mới còn cần các bước tay ở Dashboard (xem 12.11) trước khi dùng được.

### 12.11. Việc còn để ngỏ / bắt buộc làm trước khi coi là "xong"

- **⚠️ Quan trọng nhất**: đã đổi `config.js` sang project Supabase MỚI (`mnhlddcvbzihhnnirhiz.supabase.co`, xem lịch sử mục 15) nhưng **project mới CHƯA chạy `schema.sql`, CHƯA deploy Edge Function `admin-users`, CHƯA bật Anonymous sign-in, CHƯA có tài khoản Admin**. Các bước tay còn lại trên Supabase Dashboard (người vận hành tự làm, KHÔNG đưa mật khẩu/service_role key cho AI):
  1. SQL Editor → dán toàn bộ `supabase/schema.sql` (repo này) → Run (an toàn chạy lại nhiều lần).
  2. Authentication → Sign In / Providers → bật **"Allow anonymous sign-ins"** (bắt buộc, tầng User dựa vào đây).
  3. Authentication → Users → **Add user** → tạo tài khoản Admin `binh.dang@ild-coffee.com` + đặt mật khẩu (tự làm, không đưa cho AI).
  4. SQL Editor → chạy (SAU khi đã tạo user ở bước 3 — `display_name` là NOT NULL nên phải truyền giá trị, đổi tên hiển thị nếu muốn):
     ```sql
     insert into public.gmp_members (user_id, display_name, role, disabled)
     select id, 'Đặng Thanh Bình', 'admin', false
     from auth.users
     where email = 'binh.dang@ild-coffee.com'
     on conflict (user_id) do update set role = 'admin', disabled = false;
     ```
     Kiểm tra lại: `select m.role, m.disabled, u.email from public.gmp_members m join auth.users u on u.id=m.user_id where u.email='binh.dang@ild-coffee.com';` phải trả về đúng 1 dòng `role=admin, disabled=false`.
  5. Deploy Edge Function: `npx supabase login` → `npx supabase link --project-ref mnhlddcvbzihhnnirhiz` → `npx supabase functions deploy admin-users` (chạy từ thư mục gốc repo này, cần Supabase CLI).
  6. Authentication → URL Configuration → Site URL đặt đúng URL GitHub Pages đang publish của repo này.
  7. Kiểm tra lại `config.js` đã publish (GitHub Pages) khớp `url`/`anonKey` mới, mở app thử đăng nhập tầng User (chọn tên + Mã NV) và tầng Admin (email/mật khẩu vừa tạo).
- Chưa test end-to-end với Supabase/GitHub Pages thật cho TOÀN BỘ mục 12 trên project MỚI này (đăng nhập thật, RLS/RPC trên dữ liệu thật, Realtime SUBSCRIBED thật, đồng bộ 2 máy thật, upload ảnh bucket thật) — mọi test trong quá trình làm (viết mục 12, 2 đợt audit Egress) đều qua bản sao cách ly/mock `SB`, chưa chạy trên project thật (cũ hay mới).
- Cân nhắc mở rộng `gmp_purge_finalized_candidates` cho kỳ đã chốt hẳn (hiện chỉ áp dụng kỳ đang mở, xem 12.9) nếu thực tế cần dọn dữ liệu cũ thường xuyên.
- `schema.sql`/Edge Function `admin-users` giờ **sống chính thức trong repo này** (`supabase/`) — bản ở `C:\Apps\GMP_Score_App` coi là lưu trữ cũ, đừng sửa ở đó nữa (xem cảnh báo đầu mục 12).
- Dữ liệu cũ trên project `thhevdrgbxvyatfvtyrh.supabase.co` (nếu có) **không tự chuyển** sang project mới — nếu cần giữ lại lịch sử chấm điểm cũ, phải tự export/import dữ liệu (chưa có script cho việc này).
- Ảnh cũ (base64 trong DB, hoặc upload lên Storage trước đợt audit lần 2) chưa được nén lại — chỉ ảnh mới từ giờ mới nhỏ (xem `EGRESS_AUDIT.md` mục 0b).
- Cân nhắc siết RLS thật sự (không chỉ rào cản giao diện) nếu yêu cầu bảo mật tăng lên — sẽ cần bước cấp quyền phía server khi Mã NV đúng (VD đổi phiên ẩn danh thành phiên có custom claim), phức tạp hơn đáng kể so với hiện tại, cố tình chưa làm trong mục 12.
