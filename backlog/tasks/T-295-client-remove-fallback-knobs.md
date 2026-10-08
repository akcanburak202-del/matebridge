---
id: T-295
title: Tablet — T-286 `dec_wait poll` ve T-292 `aead_path legacy` yedek yollarını kaldır
status: todo
phase: 6
owner: android-client-dev
depends_on: [T-286, T-292]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/security/Records.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/DevKnobs.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoRenderer.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/VsyncIdle.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/bench/AeadDecryptBenchTest.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/security/RecordAeadPathTest.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/session/DevKnobsTest.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/DecoderWaitTest.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/VsyncIdleTest.kt
  - backlog/tasks/T-295-client-remove-fallback-knobs.md
---

## Amaç

Varsayılanlar 2026-10-07'den beri cihazda: `dec_wait=event_in` (T-286) ve `aead_path=direct` (T-292). İkisinde de eski yol "bir döngü yedek, sonra silinir" diye bırakılmıştı (`docs/KNOBS.md` 23e, 23f). O tarihten beri günlük kullanımda sorun bildirilmedi. Bu kart eski yolları ve anahtarlarını kaldırır.

## Kabul

1. **`dec_wait`:**
   - `DecoderWait.POLL` ve giriş döngüsünün sabit 4 ms yoklaması kaldırılır. `IdleWait` yalnız bu yolun parçasıysa o da kaldırılır; başka kullanıcısı varsa kalır, Handoff'ta yaz.
   - Giriş döngüsü her zaman `event_in` davranışında çalışır: kare, emeklilik ya da çıkış hatası gelene kadar park eder, 250 ms sigorta vardır.
   - Çıkış döngüsü bugünkü davranışında kalır.
   - `DecoderWait` enum'u tek değere iniyorsa enum ve `--es dec_wait` anahtarı tamamen kalkar.
2. **`aead_path`:**
   - `AeadPath.LEGACY` (`doFinal(byte[])` yolu) ve `--es aead_path` anahtarı kaldırılır. Video kaydı her zaman doğrudan `ByteBuffer` yolunu kullanır.
   - `RecordOpener` ya da benzeri soyutlama tek uygulamaya iniyorsa sadeleştirilir.
   - Video dışı kayıtlarda bugünkü yol neyse o kalır; davranış değişmez.
3. **Bilinmeyen anahtar:** artık tanınmayan `dec_wait`/`aead_path` geldiğinde DevKnobs'un genel kuralı ne diyorsa o uygulanır (yok sayma ya da `other`); çökme olmaz. `ev=profile knobs=` alanında bu iki anahtar görünmez.
4. **Testler:** testler yeni duruma göre güncellenir. Yalnız silinen yolu sınayan testler silinir. `event_in` ve `direct` davranış testleri kalır.
5. **Davranış:** varsayılan yapılandırmada değişiklik yoktur. Bu saf bir kaldırmadır, ayar ya da zamanlama değişikliği içermez.
6. **Belgeler:** `docs/KNOBS.md` satır 23e ve 23f'yi orkestratör günceller. Bu dosya kapsam dışıdır; önerilen metni Handoff'a yaz.

## Plan

## Handoff

## Open questions
