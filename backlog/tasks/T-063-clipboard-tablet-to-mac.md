---
id: T-063
title: Pano: tablet → Mac çalışmıyor
status: todo
phase: 5
owner: android-client-dev
depends_on: [T-054, T-055]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/clipboard/
  - client-android/app/src/test/
  - backlog/tasks/T-063-clipboard-tablet-to-mac.md
---

## Amaç

Kullanıcı (2026-10-01 sabah): tablette kopyalanan metin Mac'e gelmiyor; Mac → tablet çalışıyor.

**Kök neden (orkestratör, kod okuma):** tablette başka bir uygulamada kopyalanan metin MateBridge odak kazanınca `ClipboardBridge.check(fromListener=false)` ile okunuyor ve `ClipboardSync.onLocalClip(text, sensitive, desc.timestamp)` çağrılıyor. `ClipDescription.getTimestamp()` **`SystemClock.elapsedRealtime()`** tabanında (açılıştan beri ms), ama `MainActivity` `onSessionAccepted(..., System.currentTimeMillis(), ...)` ile taban zamanı **duvar saatinde** veriyor. `timestampMs in 1..baselineMs` her zaman doğru → her kopya "oturumdan önce" sayılıp yok sayılıyor. Dinleyici yolu (zaman damgası 0) yalnızca MateBridge odaktayken çalışıyor; kullanıcı orada kopyalamıyor.

## Kabul kriterleri

- [ ] Taban zamanı ve kopya zaman damgası aynı saat tabanında (`elapsedRealtime`); `ClipboardSync` KDoc'u saat tabanını açıkça söyler.
- [ ] Test (`ClipboardSync` saf): oturum kabulünden sonra kopyalanan (daha büyük `elapsedRealtime` damgası) metin gönderilir; öncesindeki gönderilmez; damga 0 (bilinmiyor) davranışı değişmez.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

`MainActivity`'deki `onSessionAccepted` çağrısında `System.currentTimeMillis()` → `SystemClock.elapsedRealtime()`; test.

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
