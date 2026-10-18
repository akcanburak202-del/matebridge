---
id: T-357
title: Kamera — "Kamerayı şimdi kapat" (release_seq) ve boşta kullanım denetimi (karar 0040 ek 2, politika C)
status: todo
phase: 7
owner: mac-host-dev + android-client-dev
depends_on: [T-354, T-355]
decisions: [0040]
files:
  - host-mac/Sources/
  - host-mac/Tests/
  - client-android/app/src/main/
  - client-android/app/src/test/
  - docs/KNOBS.md
  - docs/LOGGING.md
  - backlog/tasks/T-357-camera-release-and-idle-stop.md
---

## Amaç

Karar 0040 ek 2 ve PROTOCOL.md (dal `task/T-356-camera-integration`, commit 2e417246): `CAMERA_PREFS.reserved` → `release_seq`; kullanım bitişi politikası C. Fixture `camera_prefs_auto` değişti (release_seq = 2).

## Host

1. Kodek: `CAMERA_PREFS.release_seq` (fixture testleri).
2. `release_seq` değişimi: START durumundaysa STOP + **bırakılmış** durum. Bırakılmışken START yok; host yazmıyorken kullanım 0 görülüp sonra yeniden 1 olunca bırakılmış durum kalkar ve normal kural işler. `mode` OFF'a geçiş de temizler. Oturum başında `release_seq` taban değeri ilk gelen değerdir (değişim sayılmaz).
3. **Periyodik denetimi kaldır** (T-354'ün 15 sn'lik `MATEBRIDGE_CAMERA_PROBE_S` yolu). Yerine: yazarken yalnız (a) Mac'te kullanıcı girdisi 10 dk yokken (`CGEventSourceSecondsSinceLastEventType`, combinedSession, any input) ve boşta kaldıkça her 10 dk'da bir, (b) Mac uykuya ya da ekran uykusuna giderken (`NSWorkspace` willSleep / screensDidSleep) kısa denetim (sink'i durdur, kullanımı oku, kullanım varsa yazıma dön). Kullanım yoksa STOP. Denetim aralığı ve boşta eşiği için knob (`MATEBRIDGE_CAMERA_IDLE_S`, varsayılan 600) KNOBS.md'de; eski knob silinir.
4. Durdurma süresini ölç ve kısalt: özelliğin düşmesi için gereken en kısa bekleme (T-354 0,6 sn kullandı; dinleyiciyle erken çık).
5. Mac menüsündeki "kullanımda say (elle)" öğesi kalabilir; davranışı: açıkken boşta denetim de yapılmaz.
6. Testler: release_seq tablosu (START'ta değişim → STOP + bırakılmış; bırakılmışken kullanım 1 kalırsa START yok; 1→0→1 sonrası START; OFF temizler; ilk değer değişim değil), boşta denetim zamanlaması (sahte saat, sahte girdi yaşı), uyku olayı.

## İstemci

1. Kodek: `CAMERA_PREFS.release_seq` (fixture testleri).
2. Panel: Kamera bölümünde, kamera **akarken** (START + bağlantı kurulu) görünen bir eylem: "Kamerayı şimdi kapat". Basınca `release_seq` +1 (oturum içinde sayaç; oturum başında 0) ve hemen `CAMERA_PREFS` gönder. Mevcut öğe türleriyle (Action, `hidden`); T-352 görünüm kodu Action'ları en alta topluyor: bu eylem kamera bölümünde kalmalı (gerekirse `SettingsViews`'te Action'ı yerinde bırakan küçük bir bayrak, ör. `inline = true`; diğer eylemlerin yeri değişmez).
3. Testler: sayaç ve gönderim, görünürlük.

## Kabul

- `./scripts/check.sh` tam olarak geçer.
- Cihaz testi orkestratörde.

## Plan

## Handoff

## Open questions
