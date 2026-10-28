# Plan 3: Environment Doctor & Shell Auto-Completions

## Triage
- **Workstream**: code
- **Risk**: low
- **Complexity**: moderate
- **Needs human**: no

## Goal
Cung cấp lệnh kiểm tra và chẩn đoán môi trường toàn diện `squad-devkit --doctor`, đồng thời tạo bộ shell completions cho Bash và Zsh giúp cải thiện tốc độ và trải nghiệm dòng lệnh cho developer.

---

## Tasks

### Task 3.1: Xây dựng lệnh `squad-devkit --doctor`
- **Role**: `dev`
- **Files you own**:
  - `scripts/squad-devkit.sh`
  - `docs/squad-devkit.md`
  - `tests/squad_devkit_launcher_smoke.sh`
- **Context files**:
  - `scripts/lib/squad-devkit-agents.sh`
  - `scripts/lib/squad-panes.sh`
- **Exact changes**:
  1. Trong `scripts/squad-devkit.sh`:
     - Thêm cờ `--doctor` vào `usage()` và bộ phân tích tham số command line (`doctor=1`).
     - Viết hàm `run_doctor()` xuất bảng trạng thái môi trường:
       - **Core Tools**: Kiểm tra `squad`, `git`, `jq`, `curl`, `tmux` (ghi rõ path và phiên bản nếu có).
       - **Manager CLI**: Hiển thị CLI manager mặc định/được lưu và các manager CLI khác có trong máy.
       - **Worker Engines**: Hiển thị các worker engine tìm thấy theo thứ tự ưu tiên (`claude`, `codex`, `grok`, `agy`, `ccr`,...).
       - **Terminal & Monitor Support**: Kiểm tra `TERM_PROGRAM`, các biến môi trường multiplexer/terminal (`TMUX`, `KITTY_WINDOW_ID`, `WEZTERM_PANE`, `ZELLIJ`,...) và thông báo chế độ hiển thị pane tương ứng.
       - Trả về exit code 0 nếu đáp ứng các công cụ bắt buộc (`squad`, `git`, `jq` và ít nhất 1 manager CLI), ngược lại exit 1.
  2. Trong `docs/squad-devkit.md`: Bổ sung tài liệu giải thích chức năng của `--doctor`.
  3. Trong `tests/squad_devkit_launcher_smoke.sh`: Thêm smoke test cho lệnh `squad-devkit --doctor`.
- **Steps**:
  1. Xây dựng hàm `run_doctor()` trong `scripts/squad-devkit.sh`.
  2. Đấu nối cờ `--doctor` trong vòng lặp parse options.
  3. Cập nhật `docs/squad-devkit.md`.
  4. Viết smoke test trong `tests/squad_devkit_launcher_smoke.sh`.
  5. Chạy shellcheck và smoke test.
- **Acceptance Criteria**:
  - `squad-devkit --doctor` in ra thông tin rõ ràng, không gây side-effect (không tạo thư mục `.squad`).
  - Thoát với exit code chuẩn xác theo tính sẵn sàng của môi trường.
- **Verification Commands**:
  ```bash
  shellcheck -S warning scripts/squad-devkit.sh
  bash tests/squad_devkit_launcher_smoke.sh
  ```

---

### Task 3.2: Tạo Shell Completions cho Bash & Zsh
- **Role**: `dev`
- **Files you own**:
  - `scripts/completions/squad-devkit.bash` (new file)
  - `scripts/completions/_squad-devkit` (new file)
  - `scripts/install-devkit.sh`
  - `tests/squad_devkit_manager_choice_smoke.sh`
- **Context files**:
  - `README.md`
- **Exact changes**:
  1. Tạo `scripts/completions/squad-devkit.bash`:
     - Viết hàm completion cho `squad-devkit`: gợi ý cờ `--manager`, `--setup`, `--list`, `--clean`, `--clean-all`, `--doctor`, `--dry-run`, `--task`, `--ghostty`, `--tmux`, `--version` và gợi ý danh sách manager CLI cho `--manager`.
     - Viết hàm completion cho `squad-worker`: gợi ý các cờ và gợi ý động các worker ID đang chạy (`squad-worker --stop <TAB>`), các worktree unmerged (`squad-worker --merge <TAB>`, `--diff <TAB>`, `--discard <TAB>`).
     - Viết hàm completion cho `squad-monitor`.
  2. Tạo `scripts/completions/_squad-devkit`: Hoàn thiện định dạng zsh completion tương đương.
  3. Trong `scripts/install-devkit.sh`: Thêm thông báo hướng dẫn người dùng source file completion vào `~/.bashrc` hoặc `~/.zshrc`.
  4. Trong `tests/squad_devkit_manager_choice_smoke.sh`: Thêm kiểm tra cú pháp file bash completion (`bash -n scripts/completions/squad-devkit.bash`).
- **Steps**:
  1. Viết mã nguồn cho 2 file completion trong `scripts/completions/`.
  2. Cập nhật output của `scripts/install-devkit.sh`.
  3. Thêm test kiểm tra cú pháp vào `tests/squad_devkit_manager_choice_smoke.sh`.
  4. Chạy shellcheck và test suite.
- **Acceptance Criteria**:
  - File script completion hợp lệ cú pháp, không có lỗi runtime khi source.
  - Gợi ý đúng các option và giá trị động.
- **Verification Commands**:
  ```bash
  shellcheck -S warning scripts/completions/squad-devkit.bash scripts/install-devkit.sh
  bash -n scripts/completions/squad-devkit.bash
  bash tests/squad_devkit_manager_choice_smoke.sh
  ```
