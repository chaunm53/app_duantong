doc: 00_HienPhapDuAn_TONG 
version: 2.0 
owner: Nguyễn Xuân Vinh 
updated: 2025-08-28
# **HIẾN PHÁP DỰ ÁN HỆ SINH THÁI — v2.0**

*Tài liệu này là bộ quy tắc nền tảng và bất biến, áp dụng cho TẤT CẢ các sản phẩm và dịch vụ trong hệ sinh thái. Mọi thành viên, bao gồm con người và AI Agent, phải tuân thủ nghiêm ngặt các nguyên tắc dưới đây.*

---

## **PHẦN A: NGUYÊN TẮC VỀ KIẾN TRÚC & DỮ LIỆU**

### **Điều 1: Kiến trúc Lõi & Vệ tinh (Hub & Spoke)**
1.1. **Lõi IAM là Nguồn Sự thật Duy nhất (SSOT):** Một CSDL/dịch vụ trung tâm (`iam-core`) quản lý định danh (users, profiles) và các tài sản chung (điểm thưởng) của toàn hệ sinh thái.
1.2. **Vệ tinh Độc lập:** Mỗi ứng dụng/dịch vụ (App Bán hàng, Web Xổ số...) là một "vệ tinh" với CSDL nghiệp vụ riêng, chỉ tham chiếu đến Lõi qua `user_id` (UUID) và không sao chép dữ liệu người dùng.
1.3. **`schema.sql` là Luật:** Mọi thay đổi cấu trúc CSDL phải được thực hiện dưới dạng file migration được quản lý phiên bản.

### **Điều 2: Giao tiếp API-First & Hợp đồng Bất biến**
2.1. **Mọi Giao tiếp qua API:** Tương tác giữa các thành phần (Frontend ↔ Backend, Backend ↔ Backend) phải thông qua API/Webhook đã được định nghĩa.
2.2. **JSON Schema là Hợp đồng:** Mọi payload phải tuân thủ một JSON Schema được định nghĩa và lưu trữ tại `/contracts`.
2.3. **Versioning Bắt buộc:** Không phá vỡ tương thích ngược của một API đã phát hành. Các thay đổi lớn phải ra phiên bản mới (v1, v2...) và có hướng dẫn chuyển đổi (migration guide).

### **Điều 3: Frontend "Nhẹ", Backend "Nặng"**
3.1. **Frontend (UI Layer):** Chỉ chịu trách nhiệm hiển thị dữ liệu và thu thập hành động của người dùng.
3.2. **Backend (Business Logic Layer):** Chịu trách nhiệm toàn bộ logic nghiệp vụ, tính toán, xác thực và quản lý trạng thái dữ liệu.

### **Điều 4: Đồng nhất Dữ liệu Toàn Hệ thống**
4.1. **Định danh:** Luôn sử dụng `UUID` làm khóa chính và khóa ngoại.
4.2. **Thời gian:** Lưu trữ tất cả timestamps trong CSDL dưới dạng **UTC**.
4.3. **Xóa dữ liệu:** Ưu tiên "xóa mềm" (`deleted_at`) cho các bản ghi quan trọng thay vì xóa cứng.

---

## **PHẦN B: NGUYÊN TẮC VỀ CHẤT LƯỢNG & VẬN HÀNH**

### **Điều 5: Cổng Chất lượng & Kiểm thử (Quality Gates)**
5.1. **Tự động hóa Kiểm tra (CI):** Mọi thay đổi về code phải vượt qua các bài kiểm tra tự động: linting (kiểm tra lỗi chính tả code), type checking (kiểm tra kiểu dữ liệu), và contract testing (kiểm tra payload có khớp với JSON Schema không).
5.2. **Kiểm thử Thủ công:** Các luồng chức năng quan trọng phải được kiểm thử End-to-End (E2E) theo kịch bản trước khi phát hành.

### **Điều 6: Cam kết Hiệu năng (Performance)**
6.1. **Tốc độ Phản hồi (Latency):** API đọc dữ liệu cho người dùng phải có thời gian phản hồi dưới 300ms (p95). API ghi dữ liệu phải dưới 600ms (p95).
6.2. **Tối ưu Truy vấn:** Cấm `SELECT *` trên các bảng lớn. Mọi truy vấn nặng phải có kế hoạch sử dụng chỉ mục (index).
6.3. **Phân trang (Pagination):** Bất kỳ danh sách nào trả về có khả năng lớn hơn 100 bản ghi đều phải được phân trang.

### **Điều 7: Khả năng Quan sát & Phản ứng Sự cố (Observability & Incident Response)**
7.1. **Logging Chuẩn hóa:** Mọi log phải có cấu trúc (structured log) và chứa các thông tin tối thiểu: `request_id`, `tenant_id`, `user_id`.
7.2. **Cảnh báo (Alerts):** Thiết lập cảnh báo tự động cho các chỉ số quan trọng: tỷ lệ lỗi server (5xx), độ trễ API tăng cao, hàng đợi xử lý bị đầy.
7.3. **Sổ tay Vận hành (Runbook):** Phải có tài liệu hướng dẫn xử lý cho các sự cố thường gặp.

### **Điều 8: Quản lý Thay đổi & Phát hành (Change & Release Management)**
8.1. **Môi trường Tách biệt:** Duy trì ít nhất 3 môi trường: `development` (phát triển), `staging` (thử nghiệm nội bộ), và `production` (cho người dùng thật).
8.2. **Kế hoạch Rollback:** Mọi phiên bản phát hành phải có kế hoạch để quay lui về phiên bản trước đó nếu có sự cố nghiêm trọng.
8.3. **Feature Flags:** Sử dụng cờ tính năng để bật/tắt các tính năng lớn hoặc rủi ro cao mà không cần triển khai lại code.

---

## **PHẦN C: NGUYÊN TẮC VỀ BẢO MẬT & QUẢN TRỊ**

### **Điều 9: Bảo mật Đa tầng (Security)**
9.1. **Row Level Security (RLS) là Bắt buộc:** Tất cả các bảng CSDL chứa dữ liệu của người dùng/hộ kinh doanh phải được bật RLS.
9.2. **Quản lý Bí mật (Secrets Management):** API keys, mật khẩu... phải được quản lý qua biến môi trường hoặc dịch vụ quản lý bí mật, không bao giờ được lưu trong source code.
9.3. **Phòng chống Lạm dụng:** Triển khai giới hạn tần suất truy cập (rate-limiting) cho các API công khai. Các API ghi dữ liệu phải hỗ trợ `Idempotency-Key` để tránh giao dịch trùng lặp.

### **Điều 10: Quản trị Dữ liệu & Quyền Riêng tư (Data Governance)**
10.1. **Phân loại Dữ liệu:** Phân loại và đánh dấu các loại dữ liệu nhạy cảm (PII - Personally Identifiable Information).
10.2. **Chính sách Lưu trữ (Retention Policy):** Định nghĩa rõ ràng thời gian lưu trữ cho từng loại dữ liệu (ví dụ: logs, giao dịch...).
10.3. **Quyền truy cập Tối thiểu (Least Privilege):** Các tài khoản dịch vụ và người dùng chỉ được cấp những quyền hạn tối thiểu cần thiết để hoàn thành công việc.

### **Điều 11: Sao lưu & Phục hồi (Backup & Disaster Recovery)**
11.1. **Sao lưu Tự động:** CSDL phải được sao lưu tự động hàng ngày.
11.2. **Mục tiêu Phục hồi (RPO/RTO):** Xác định rõ mục tiêu về lượng dữ liệu tối đa có thể mất (RPO) và thời gian tối đa để phục hồi hệ thống (RTO) sau thảm họa.
11.3. **Diễn tập Phục hồi:** Thực hiện diễn tập khôi phục từ bản sao lưu ít nhất mỗi quý.

---

## **PHẦN D: NGUYÊN TẮC VỀ QUY TRÌNH LÀM VIỆC**

### **Điều 12: Quy trình Cộng tác với AI (AI Collaboration Protocol)**
12.1. **Cung cấp Bối cảnh (Briefing):** Mọi yêu cầu cho AI phải bắt đầu bằng việc cung cấp bối cảnh đầy đủ, bao gồm các link đến các tài liệu liên quan trong "Bộ não Chung".
12.2. **Kiểm tra Chéo (Cross-AI Review):** Sản phẩm đầu ra của một AI Agent phải được kiểm tra chéo bởi một AI Agent khác (hoặc con người) dựa trên một checklist đã định nghĩa trước.
12.3. **Tóm tắt & Ghi nhận (Debriefing):** Sau khi hoàn thành một tác vụ, phải có một bản tóm tắt được ghi vào "Nhật ký Dự án".

### **Điều 13: Tài liệu & Quản lý Quyết định**
13.1. **Cập nhật Tài liệu:** Các tài liệu thiết kế (API, CSDL) phải được cập nhật đồng thời với code.
13.2. **Architecture Decision Records (ADR):** Mọi quyết định kiến trúc quan trọng phải được ghi lại dưới dạng một file ADR, giải thích rõ vấn đề, các lựa chọn và lý do cho quyết định cuối cùng.

### **Điều 14: Quy ước Chung**
14.1. **Thiết kế:** Giao diện trên các sản phẩm phải tuân thủ hệ thống thiết kế chung (`packages/ui-kit`).
14.2. **Đặt tên:** Tuân thủ quy ước đặt tên đã định cho CSDL, API, và Code.
