## Unreleased

* fix(login): bump `zpw_ver` 671 → 685 cho khớp API version hiện hành của Zalo
  (port zca-js PR #327) — version cũ bị server từ chối gây lỗi session/đăng nhập.
* fix(login): suy `sec-ch-ua` và `sec-ch-ua-platform` trực tiếp từ User-Agent
  thay vì hardcode (port zca-js PR #303) — đảm bảo client hints luôn khớp UA,
  tránh anti-bot Zalo phát hiện fingerprint mismatch và ban session.
* fix(listener): bỏ qua gói tin realtime không giải mã được thay vì để lỗi làm
  sập listener (port zca-js PR #303) — bình thường với một số event reaction/hệ thống.

## 0.0.1

* TODO: Describe initial release.
