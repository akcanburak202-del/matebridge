---
id: T-275
title: Host — yerel imleç (0036): imleç izleyici, CURSOR_SHAPE/STATE gönderimi, videoda imleci kapatma
status: todo
phase: 6
owner: mac-host-dev
depends_on: [T-274]
decisions: [0036]
files:
  - host-mac/Sources/MateBridgeCore/
  - host-mac/Sources/MateBridgeHost/
  - host-mac/Tests/MateBridgeCoreTests/
  - docs/LOGGING.md
  - backlog/tasks/T-275-host-local-cursor.md
---

## Amaç

Karar 0036, PROTOCOL (dal `task/T-274-cursor-protocol`): HELLO bit13, 0x0B/0x0C/0x0D, §5 imleç kuyruğu. **Bu dalı `task/T-274-cursor-protocol` üzerine kur.** Bilgi kaynağı T-271 probu (`probes/cursor-probe`, NOTES 2026-10-06 ~13:50): `NSCursor.currentSystem` (şekil, hotspot, temsiller), `CGCursorIsVisible` (dlsym; T-272'deki `SystemCursorVisibility` yeniden kullanılır), konum `CGEvent(source:nil).location`.

## Kabul

1. Core: kodekler (`CURSOR_PREFS`, `CURSOR_SHAPE`, `CURSOR_STATE`), bit13; bütün yeni fixture'lar `FixtureTests`'te. Saf `CursorStreamPlanner`: PREFS → açma/kapama sırası (önce SHAPE + STATE, sonra video imleci kapat; kapatırken önce video imleci aç), değişiklikte STATE (en sık ~8 ms, en yenisi kazanır), en az 500 ms'de bir STATE, şekil önbelleği 32 LRU (kullanım = SHAPE ya da STATE referansı), oturum sonunda temizlik. Normalize konum: §1 girdi eşlemesinin tersi (sanal ekran sınırları, kenara sıkıştırma; oyun ekranı 1x dahil). Testli.
2. Host: imleç izleyici yalnız PREFS(1) iken çalışır (~120 Hz yoklama + her `POINTER_*`/kalem/dokunma enjeksiyonundan hemen sonra bir örnek). Şekil özeti (görüntü baytları + hotspot) değişince en uygun temsil seçilir, ≤ 128×128 px'e küçültülür, PNG'ye (ImageIO, yeni bağımlılık yok) ≤ 61 440 bayt kodlanır. Ana iş parçacığı gerekiyorsa ona göre; maliyet ölçülüp log'a.
3. Video: `ScreenCapture` `showsCursor`'ı akışı kurmadan değiştirir (`SCStream.updateConfiguration`); başarısızsa video imleci kalır ve `CURSOR_*` gönderilmez (protokoldeki "uygulayamazsa" kuralı). Oturum sonu/devralma/uyku → video imleci geri açık.
4. Gönderim kontrol bağlantısında H→C; girdi yönünü (C→H) etkilemez. Tıkanmada STATE beklemez (tek bekleyen, en yenisi).
5. Log: `ev=cursor_prefs enabled=`, `ev=cursor_video shows=0|1`, saniyelik sayaçlar (state, shape, örnek maliyeti p50/p95 µs); şekil görüntüsü/konum dökümü yok.
6. Mac'te pencere açma; testte imleci hareket ettirme, tıklama, enjeksiyon yapma; çalışan host'a dokunma. `./scripts/check.sh` (istemci fixture testi T-276 gelene kadar yalnız yeni fixture'lar yüzünden düşebilir — açıkça yaz).

## Plan

(ajan doldurur)

## Handoff

## Open questions
