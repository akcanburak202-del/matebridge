---
id: T-251
title: Client — 120 Hz pacer diagnostics: log feedback level, dev knobs for D cap and feedback
status: done
phase: 6
owner: android-client-dev
depends_on: []
decisions: [0014, 0021]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/DevKnobs.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - backlog/tasks/T-251-client-pacer-120-diagnostics.md
---

## Amaç

NOTES 2026-10-05 ~17:20: gerçek 120-on-120 (panel 120 Hz, akış 120 fps, n=1) atlama ölçümü hiç yapılmadı. Çözme gecikmesi ~13 ms, p99 ~18–20 ms (T-249). Cihaz oturumunda yeniden APK kurmadan hipotezleri A/B edebilmek için tanı alanları ve geliştirici düğmeleri gerekiyor. Varsayılan davranış DEĞİŞMEZ.

## Bağlam

- `video/AdaptivePacer.kt`: D tavanları (~205–207: n=1 → 1 periyot, n=2 → 1,5 periyot; `MAX_D_HALF_PERIODS`), gecikme sınırları (~233, ~275), `onSkipWindow` histerezisi (~424–433: %1–3 arasında seviye ne iner ne çıkar), `recadence()` (~450). `FramePacer.kt`: lead 6 ms, deadline 6 ms (mevcut `--ei deadline_us`, `--ei lead_us` düğmeleri `--ez dev true` ile).
- İstenen:
  1. `ev=present` (ya da pacer'ın mevcut log satırı) içine geri besleme `level` ve D'nin bileşenleri (jitter p99, slack, cap) eklensin; `pace_trace` CSV'sine de `level`.
  2. Geliştirici düğmeleri (DevKnobs, `--ez dev true` gerektirsin; yoksa yok sayılır, mevcut desen): `--ei pace_dcap_half N` (n=1 ve n=2 tavanlarını N yarım periyot yapar; gecikme sınırları da tutarlı ölçeklensin), `--ez pace_feedback false` (geri besleme seviyesini 0'da sabitler).
  3. `ev=stats` satırında hangi pacer düğmelerinin etkin olduğu bir kez loglansın (oturum başında).
- Gizlilik/log kuralları: `docs/LOGGING.md`.

## Kabul kriterleri

- [ ] Düğmeler yokken davranış ve testler aynı (varsayılan değişmez).
- [ ] Yeni alanlar logda; birim testleri düğme ayrıştırma + tavan ölçekleme için.
- [ ] `./scripts/check.sh` geçer.
- [ ] Handoff: cihaz oturumu için hazır komut satırları (Günlük 120 ve Oyun 120; varsayılan / `deadline_us 4000` / `pace_dcap_half 3` / `pace_feedback false`) ve hangi alanın neyi doğruladığı.

## Plan

1. `video/PacerTuning.kt` (saf, JVM testli): `PacerTuning(dCapHalf, feedback)`; `capHalfFor(n)` (varsayılan n=1: 2, n=2: 3 yarım periyot), `boundExtraHalf(n)` (yalnız yerleşik tavanın ÜSTÜNDEKİ artış gecikme sınırlarını genişletir: kilitli `latencyBound` ve kilitsiz `limit`), `parse` (N<1 yok sayılır, N>8 kırpılır). `PacerDiag` log alanları.
2. `AdaptivePacer(vsync, interval, tuning)`: D tavanı `tuning.capHalfFor(n)`; `pace_feedback=false` iken `onSkipWindow` hiçbir şey yapmaz (seviye 0). Varsayılanda sayılar aynı. `lastJitterNs`/`lastCapNs`/`diag()`.
3. Log: `render ev=present` sonuna `fb_level= d_jitter_us= d_extra_us= d_cap_us=` (pacer yoksa `-`). `PaceTrace` CSV'sine son sütun `level` (probe.level).
4. `DevKnobs`: `pace_dcap_half` (INT), `pace_feedback` (BOOL), ikisi debug-only (`--ez dev true`), `knobs=` profil satırında listelenir. `MainActivity`: `renderer.pacerTuning`; renderer başına ilk `render ev=stats` satırına bir kez `pacer_knobs=<-|pace_dcap_half:N;pace_feedback:0>`.

## Handoff

- Dal: `task/T-251-pacer-diag`; commit SHA: `git log -1 task/T-251-pacer-diag` (tek commit, `T-251: ...`).
- Dosyalar: `video/PacerTuning.kt` (yeni), `video/AdaptivePacer.kt`, `video/PaceTrace.kt`, `video/VideoRenderer.kt`, `session/DevKnobs.kt`, `MainActivity.kt`; testler `video/PacerTuningTest.kt` (yeni), `DevKnobsTest`, `PaceTraceTest`, `PresentationMetricTest`, `CallbackPresentationMetricTest` (son üçü yalnız yeni son CSV sütununa uyarlandı).
- check.sh: ALL OK.
- Varsayımlar: pace_trace CSV'ye `level` SONA eklendi (`tools/pacing/sim.py` sütunları başlıktan okur, etkilenmez). `pace_dcap_half N` n=1 ve n=2 tavanlarını N yarım periyot yapar (N<1 yok sayılır, N>8 kırpılır); N yerleşik tavandan büyükse gecikme sınırları (kilitli `latencyBound`, kilitsiz `limit`) (N − yerleşik)/2 periyot genişler, küçükse sınırlar değişmez. "surplus" (içerik panelden hızlı) dalının tavanı (period+margin) değişmedi. `pace_feedback false` yalnız seviyeyi 0'da tutar. `docs/LOGGING.md` kapsam dışıydı (dosya listesinde yok): yeni alanlar orada belgelenmedi, orkestratör eklesin.
- Yeni log alanları: `render ev=present ... fb_level=<0..2|-> d_jitter_us=<p99 jitter> d_extra_us=<geri besleme payı> d_cap_us=<D tavanı>`; `render ev=stats ... pacer_knobs=<-|...>` (renderer başına bir kez); `ev=profile knobs=` artık `pace_dcap_half:N`, `pace_feedback:0` da listeler.
- Tabletle test EDİLMEDİ.

### Cihaz oturumu komutları

Mod (Günlük 120 / Oyun 120) uygulama ayarından seçilir; her koşudan önce `am force-stop dev.matebridge.client`. `A=dev.matebridge.client/.MainActivity`:

```
adb shell am start -n $A --ez dev true --ez pace_trace true                                  # varsayılan
adb shell am start -n $A --ez dev true --ez pace_trace true --ei deadline_us 4000            # deadline 4 ms
adb shell am start -n $A --ez dev true --ez pace_trace true --ei pace_dcap_half 3            # D tavanı 1,5 periyot
adb shell am start -n $A --ez dev true --ez pace_trace true --ez pace_feedback false         # geri besleme kapalı
```

Her koşuda log: `adb logcat -s 'MB:*' | grep -E "ev=present|ev=stats|ev=profile"`; trace: `adb exec-out run-as dev.matebridge.client cat cache/pace_trace.csv`.

Ne doğrular:
- `ev=profile knobs=` / `pacer_knobs=`: düğme gerçekten etkin mi (dev kapısı: `--ez dev true` olmadan `ev=dev_knobs ignored=` listesinde).
- `fb_level`: 120-on-120'de geri beslemenin seviyeyi yükseltip yükseltmediği (`pace_feedback false` ile 0 sabit olmalı; atlama farkı = geri beslemenin etkisi).
- `d_jitter_us` / `d_extra_us` / `d_cap_us` ve `pace_d_us`: D tavana (`d_cap_us`) yapışıyor mu? `pace_dcap_half 3` ile `d_cap_us` ≈ 12500 (120 Hz) olmalı; atlama (`skip_pct`, `hold_*`) düşerse tavan darboğazdır.
- trace `level` sütunu: seviye değişimlerinin hangi karelerde olduğu.

## Open questions
