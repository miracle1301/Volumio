# Volumio

Menu bar app chỉnh âm lượng riêng cho từng ứng dụng trên macOS (14.4+), dùng Core Audio Process Taps — không cần cài driver âm thanh ảo.

## Build & chạy

    ./build.sh
    open build/Volumio.app

Lần đầu kéo slider khác 100%, macOS sẽ hỏi quyền **System Audio Recording**. Nếu lỡ từ chối: System Settings → Privacy & Security → Screen & System Audio Recording → bật Volumio.

## Cách hoạt động

- Liệt kê các process đang dùng Core Audio, gom helper/XPC (Chrome Helper, WebKit GPU…) về app cha.
- Khi một app có âm lượng ≠ 100% (hoặc bị mute): tạo process tap (mute luồng gốc) + aggregate device trỏ tới loa hiện tại, rồi phát lại với gain mới (0–150%).
- Về 100% thì gỡ tap, âm thanh đi đường gốc. Tự dựng lại khi đổi thiết bị output.
- Mức âm lượng được lưu theo bundle ID.

## Tính năng

- Âm lượng riêng cho từng app (0–150%), tắt tiếng từng app hoặc tất cả
- Âm lượng & tắt tiếng hệ thống, chọn thiết bị phát (kèm AirPlay)
- Cuộn chuột trên biểu tượng thanh menu hoặc trên từng dòng để chỉnh âm lượng
- Tự giảm nhạc còn 20% khi Premiere/Final Cut/DaVinci phát hoặc khi có cuộc gọi (app dùng micro)
- Khởi động cùng máy, tự cập nhật (Sparkle)

## Cài đặt

Tải `Volumio-x.y.dmg` ở [Releases](https://github.com/miracle1301/Volumio/releases/latest), kéo vào Applications.
App chưa được Apple notarize nên lần đầu mở: System Settings → Privacy & Security → **Open Anyway**.

## Phát hành bản mới

    ./release.sh 1.2 "Mô tả thay đổi"

Script tăng version, build DMG + zip, ký bản cập nhật bằng khoá Sparkle (login keychain, account `Volumio`),
tạo `appcast.xml` và đăng GitHub Release `v1.2`. Các máy đã cài sẽ tự cập nhật trong vòng 24 giờ.

**Khoá ký cập nhật**: bản sao lưu ở `~/Documents/Claude AI Files/Volumio-keys/` — không đưa lên Git. Mất khoá thì
các bản đã cài không nhận cập nhật mới nữa. Khôi phục trên máy khác:
`.build/artifacts/sparkle/Sparkle/bin/generate_keys --account Volumio -f <file khoá>`.
