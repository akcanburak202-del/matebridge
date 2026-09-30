---
id: T-055
title: Tablet — pano paylaşımı (CLIPBOARD, metin)
status: review
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

1. Codec: `Clipboard` mesajı (Messages.kt) + Codec encode/decode; fixture testleri.
2. `clipboard/ClipboardSync.kt` (saf mantık): gönderim kararı (ayar, ACCEPTED, gizli, boş, >60000 bayt, yankı özeti, tekrar), gelen metin doğrulama (UTF-8, kind), seq sayacı.
3. `clipboard/ClipboardBridge.kt` (Android): ClipboardManager dinleyici, onResume denetimi, setPrimaryClip.
4. Settings'e `clipboardShare` (varsayılan açık); SessionController gelen mesajı/gönderimi bağlar; MainActivity'de küçük panel düğmesi + yaşam döngüsü kancaları.

## Handoff

- **Commit:** dal `task/T-055-client-clipboard` ucu (`proto/clipboard` merge edilmiş)
- **Dokunulan dosyalar:** protocol/Messages.kt, Codec.kt (Clipboard); session/Settings.kt (`clipboardShare`), SessionController.kt (`SessionListener.onClipboard`); yeni `clipboard/ClipboardSync.kt` (saf mantık), `clipboard/ClipboardBridge.kt` (Android); MainActivity.kt (küçük: alan, listener, odak kancası, `render` başına 1 satır, `addClipboardToggle`); testler `FixtureTest` (2 fixture) + `ClipboardSyncTest`.
- **Varsayımlar:** Oturum ACCEPTED olunca (UI `Connected`) o ana kadarki pano "zaten orada" sayılır (ClipDescription.timestamp <= kabul anı gönderilmez), yalnız sonradan kopyalananlar gider. Dinleyici pencere odaktayken (`onWindowFocusChanged`) kayıtlı; odak gelince bir kez denetim. Yankı önleme: son alınan/gönderilen metin eşitse gönderilmez (aynı metni art arda kopyalamak tekrar gitmez). Mac'ten gelen EMPTY/bilinmeyen kind/geçersiz UTF-8/boş/60000+ yok sayılır. >60000 bayt: Toast bir kez (aynı metin için). Gizli: `android.content.extra.IS_SENSITIVE` (API 33 sabiti, string literal); gizli içerik String'e bile çevrilmez. Log yalnız `ev=clipboard dir=in|out bytes=N`.
- **Test edilmeyenler / cihazda doğrulanacaklar:** `check.sh`: gradle OK; `swift test (host-mac)` FAIL (beklenen: host fixture kapsamı T-054'te, paralel). Cihazda: (1) tablette metin kopyala, Mac'te yapıştır; (2) Mac'te kopyala, tablette yapıştır, yankı/döngü yok; (3) panel düğmesi "Pano paylaşımı: açık/kapalı" kapalıyken iki yön de durur; (4) bağlanmadan önce kopyalanan metin gitmez; (5) HarmonyOS "uygulama panoya erişti" bildirimi çıkabilir; arka plandayken tablet->Mac gitmez (odak gelince denetlenir); (6) logcat'te pano içeriği yok.
- **Açık sorular:** Mac->tablet `setPrimaryClip` HarmonyOS'ta arka plandayken çalışır mı (yazma için beklenen evet) cihazda görülmeli.
