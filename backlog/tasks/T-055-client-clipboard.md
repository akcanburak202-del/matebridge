---
id: T-055
title: Tablet — pano paylaşımı (CLIPBOARD, metin)
status: todo
phase: 5
owner: android-client-dev
depends_on: [T-042]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/protocol/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/
  - client-android/app/src/main/kotlin/dev/matebridge/client/clipboard/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/
  - backlog/tasks/T-055-client-clipboard.md
---

## Amaç

PLAN Aşama 5 "pano paylaşımı". Protokol `proto/clipboard` dalında: PROTOCOL.md `0x06 CLIPBOARD`. Kart dalı `main`'den açılır, `proto/clipboard` merge edilir. Host T-054 paralel; birlikte merge edilir.

## Kabul kriterleri

- [ ] Kodek + fixture'lar (`clipboard_text`, `clipboard_empty`).
- [ ] **Tablet → Mac:** `ClipboardManager.OnPrimaryClipChangedListener` (uygulama ön planda ve odaktayken; Android 10+ arka planda panoyu okumayı engeller) ve uygulama öne gelince bir kez değişim denetimi. Yeni metin (`coerceToText`) → `CLIPBOARD(TEXT_UTF8)`, oturum `ACCEPTED`'ken ve ayar açıkken. `ClipDescription.EXTRA_IS_SENSITIVE` işaretli içerik gönderilmez. > 60 000 bayt: gönderilmez, kısa Toast bir kez.
- [ ] **Mac → tablet:** gelen metin `setPrimaryClip` ile yazılır; bunun tetiklediği dinleyici olayı geri gönderilmez (yankı önleme). Geçersiz UTF-8/`EMPTY`/bilinmeyen `kind` yok sayılır. HarmonyOS'un "uygulama panoya erişti" bildirimi çıkabilir: Handoff'ta not.
- [ ] Bağlantı panelinde "Pano paylaşımı: açık/kapalı" düğmesi (`Settings`, varsayılan açık).
- [ ] Log yalnızca yön ve uzunluk; içerik asla.
- [ ] Saf mantık (yankı önleme, sınır, gizli içerik) testli. `./scripts/check.sh` (T-054 ile birlikte) geçiyor.

## Kapsam dışı

- Görsel/dosya panosu. Host (T-054). Cihaz testi orkestratörde.

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
