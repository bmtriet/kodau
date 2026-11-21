# Checklist chạy thử Kodau trên máy thật (~10 phút)

Chạy sau mỗi thay đổi lớn. Ghi ✅ / ❌ kèm ghi chú (app đang gõ, chữ gõ vào, chữ nhận được).
Gõ trong **TextEdit** trước, sau đó lặp lại các mục quan trọng trong **Chrome** và một app chat (Slack/Messenger).

## A. Cài đặt & quyền

| # | Bước | Kỳ vọng | Kết quả |
|---|------|---------|---------|
| A1 | `make install`, mở Kodau.app | Thanh menu hiện `KD`, Dashboard mở | |
| A2 | Cài đặt hệ thống → Quyền riêng tư → Trợ năng: bật Kodau | Menu báo "Bộ gõ toàn hệ thống: Đang hoạt động" | |
| A3 | Build lại (`make app`), mở lại Kodau.app | **Quyền Trợ năng vẫn còn** (không phải bật lại) | |

## B. Gõ qua Kodau.app (layout ABC, chế độ Thông minh)

| # | Gõ | Kỳ vọng | Kết quả |
|---|----|---------|---------|
| B1 | Chế độ Tự động: `hom nay toi di lam` + Space | `hôm nay tôi đi làm` | |
| B2 | `I want to ship this today.` | Giữ nguyên tiếng Anh | |
| B3 | `D9a6u` rồi Space | `Đâu` | |
| B4 | `d9uoc75` | `được` | |
| B5 | Chế độ Thủ công: gõ `Mo ta cach hoc cua kodau, phai hoc theo context` rồi **⌥Space** (giữ Option lâu một chút) | `Mô tả cách học…` — **không mất chữ M** | |
| B6 | Shift+Return trong app chat sau một câu không dấu | Xuống dòng, **không gửi tin** | |
| B7 | ⌥Esc ngay sau khi Kodau thêm dấu | Trả về chữ không dấu | |
| B8 | Tắt "Hiện popup gợi ý từ sau khi thêm dấu", gõ `ban` + Space | Không có popup; ⌥1…5 vẫn đổi từ | |
| B9 | Click vào ô mật khẩu (Safari login) | Menu hiện 🔒, gõ không bị thêm dấu | |

## C. Học theo ngữ cảnh

| # | Bước | Kỳ vọng | Kết quả |
|---|------|---------|---------|
| C1 | Gõ `toi ban hang online`, sửa `bạn` → `bán` bằng ⌥1…5 | Lần gõ sau ra `tôi bán hàng online` | |
| C2 | Sau C1, gõ `chao ban` | Vẫn là `chào bạn` (không bị thay toàn cục) | |

## D. Bộ gõ KodauIM (Input Source "Kodau (Smart Vi/En)")

| # | Bước | Kỳ vọng | Kết quả |
|---|------|---------|---------|
| D1 | Thêm Kodau trong Input Sources → Tiếng Việt, chọn nó | Có trong menu nguồn nhập liệu | |
| D2 | `xin chao cac ban` + `.` | Chữ gạch chân khi đang gõ, chốt thành `xin chào các bạn.` | |
| D3 | Gõ xong một câu, quay lại xoá `bán` → gõ `ban5` → mũi tên phải | Toast giữa đáy màn hình: `bán → bạn`, ⌥↩ học được | |

## E. Gemini & chi phí

| # | Bước | Kỳ vọng | Kết quả |
|---|------|---------|---------|
| E1 | Chế độ Tự động + "Theo câu": gõ 1 câu dài, dừng tay vài lần, kết thúc bằng `.` | Tab Chi phí: khoảng **1–2 lượt** cho câu đó | |
| E2 | Gõ lại đúng câu đó | **Không** tăng lượt gọi (cache) | |
| E3 | Đặt giới hạn 1 lượt/ngày, gõ câu mới | Thẻ "Hạn mức hôm nay" báo đã chạm, vẫn thêm dấu offline | |
