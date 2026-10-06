---
id: T-277
title: Client test — PackedRendererTest.directPathNeverCallsAHook ara sıra düşüyor (yarış)
status: done
phase: 6
owner: android-client-dev
depends_on: []
decisions: []
files:
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - backlog/tasks/T-277-flaky-packed-renderer-test.md
---

## Amaç

`./scripts/check.sh`'ta `PackedRendererTest.directPathNeverCallsAHook` (ve bazen bir başka Android testi) yaklaşık her 2–3 koşuda bir düşüyor, tekrarında geçiyor (2026-10-06 T-266, T-269, T-272, T-276 ve 0036 birleşiminde görüldü). Kök nedeni bul (test yarışı mı, üründe gerçek bir yarış mı) ve düzelt.

## Kabul

1. Testi döngüde (ör. 50 kez, `--tests` ile tek test) koşturup düşme oranını ölç; kök nedeni Handoff'a yaz.
2. Neden testteyse testi deterministik yap (gerçek zaman beklemesi / iş parçacığı sırası yerine senkronizasyon); neden üründeyse (üretim kodunda yarış) en küçük düzeltme + test. Ürün davranışı değişmeyecek.
3. Düzeltmeden sonra 50 koşuda 0 düşme; `./scripts/check.sh` ALL OK.

## Plan

1. Düşmeyi tekrarla: testi tek süreçte döngüde (geçici tekrar sınıfı) koştur, istisnayı oku.
2. Kök neden test tarafındaysa bekleme koşulunu düzelt (üretim kodu değişmez); fake'te uyandırma eksiği varsa onu da kapat.
3. Geçici sınıfla yüklü (4 iş parçacığı) koşu, sonra 50 ayrı gradle koşusu, sonra check.sh.

## Handoff

- Commit: bu kartın commit'i (branch `task/T-277-flaky-packed-renderer-test`, tepe commit).
- Dosyalar: `client-android/app/src/test/kotlin/dev/matebridge/client/video/PackedRendererTest.kt`, `.../video/FakeDecoderCodec.kt`, bu kart. Üretim kodu (`main/`) değişmedi.
- Kök neden (test yarışı, üründe yarış yok): `directPathNeverCallsAHook` ve `packedShownTimesFeedTheScreenLatencyStats` `factory.await { codecs.single().renderedPts.isNotEmpty() }` ile bekliyordu. `await` koşulu ilk kez hemen değerlendirilir; codec'i `attachTarget` ile başlayan decoder iş parçacığı yaratır. Codec henüz yoksa `codecs` boştur ve `single()` `NoSuchElementException: List is empty` fırlatır. Diğer test (`packedReleases...`) önce `outputsDequeued >= 1` beklediği için korunuyordu. Yük altında (diğer worktree'lerde Gradle) decoder iş parçacığı geç kalınca düşme sıklaşır.
- Ölçüm (düzeltme öncesi): tek süreçte testi 300 kez art arda çağıran geçici döngüde 294/300 düştü (hepsi `List is empty`); normal check.sh koşusunda ~2-3 koşuda 1 (kart notu).
- Düzeltme: testte `FakeDecoderFactory.anyRendered()` = `codecs.firstOrNull()?.renderedPts?.isNotEmpty() == true` (codec yok = henüz değil); üç `single()` bekleyişi bununla değişti. Ek: `FakeDecoderFactory.rendered()` artık `renderedPts.add`'den sonra `lock.notifyAll()` yapıyor. Önceden `record("releaseOutput")` bildirimi `renderedPts` eklemesinden önce geliyordu; bekleyen ancak sonraki poll bildirimiyle uyanabiliyordu (şimdi deterministik).
- Ölçüm (düzeltme sonrası): geçici döngü, 4 paralel iş parçacığı x 200 tur x 6 test = 4800 çalıştırma, 0 düşme; 50 ayrı `cleanTestDebugUnitTest testDebugUnitTest --tests '*PackedRendererTest*'` Gradle koşusu: 50 geçti, 0 düştü. Geçici döngü sınıfı silindi, commit'te yok.
- Tablette denenecek bir şey yok (yalnızca JVM test değişikliği).
- `codecs.single()` başka testlerde `await` koşulu içinde kullanılmıyor (grep ile bakıldı).
- check.sh sonucu: ALL OK.

## Open questions
