---
id: T-069
title: Tablet — kare başına sunum izi (pace trace) dosyaya, deney anahtarıyla
status: done
phase: 5
owner: android-client-dev
depends_on: [T-068]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/test/
  - backlog/tasks/T-069-client-pace-trace.md
---

## Amaç

Sayaçlar (`late_drops`, `rephase`, `late_margin_*`) faz kilidinin cihazda nasıl bozulduğunu göstermeye yetmiyor. 2026-10-01 11:07–11:15 taraması (kullanıcı aktif, panel 120 Hz, akış 120): 20 sn pencerelerde `late_drops` ~1500–2200, `rephase` 36–70, geç karelerin `late_margin_p50` **+25…+60 ms** (kare kendi kilit slotundan çok önce hazır → kilit slotu gerçek varışın periyotlarca ilerisine kaymış, her ~30 karede `REPHASE_FRAMES` ile düzeliyor). Görüntüyü T-065 releaser'ı kurtarıyor. Kök nedeni bulmak için kare başına ham veri gerekli.

## Kabul kriterleri

- [ ] `--ez pace_trace true` ile (varsayılan kapalı) her çözülmüş kare için bir satır, bellekte sınırlı halka (ör. son 20 000 kare), uygulama durunca/`ev=stats` her 10 sn'de `cacheDir/pace_trace.csv`'ye yazılır (dosya boyutu sınırlı, üzerine yazılır). İçerik yok, yalnız zamanlar.
- [ ] Sütunlar (ns, `System.nanoTime` tabanı; capture µs): `seq, capture_us, ready_ns, now_vsync_last_ns, period_ns, epoch, deadline_ns, dev_ns, d_ns, jitter_ns, earliest_ns, slot_ns, lock_slot_ns, k, acquire_ns, bad_run, path(locked|acquire|sparse|unlocked), late_drop, collided, released_slot_ns, release_ns, render_ns, action(release|replace|move|discard)`. Gerekirse sütun adlarını uyarla ama karta yaz.
- [ ] İz yazımı sunum yolunu yavaşlatmaz (ön-ayrılmış dizi, tahsis yok; dosya yazımı ayrı iş parçacığında).
- [ ] Test: halka taşması ve CSV başlığı. `./scripts/check.sh` geçiyor.
- [ ] Handoff'ta çekme komutu: `adb exec-out run-as dev.matebridge.client cat cache/pace_trace.csv > …`.

## Plan

PaceTrace (önceden ayrılmış LongArray halkası, 20 000 satır x 24 sütun) + PaceProbe (AdaptivePacer her kare için ara değerleri yazar). SlotReleaser kare etiketiyle release/replace/move/discard olaylarını halkaya işler (çıkış iş parçacığı, tahsis yok). Dosya yazımı ayrı daemon iş parçacığında, geçici dosya + rename; `onSkipWindow` her 10. çağrıda ve `onStop`'ta tetiklenir. Anahtar: `--ez pace_trace true` (MainActivity, varsayılan kapalı).

## Handoff

- **Commit:** (aşağıda, SHA final raporda)
- **Dokunulan dosyalar:** video/PaceTrace.kt (yeni), video/AdaptivePacer.kt (probe), video/SlotReleaser.kt (tag/trace), video/VideoRenderer.kt, MainActivity.kt, test/.../PaceTraceTest.kt, bu kart
- **Varsayımlar:** Sütunlar kartla aynı + sona `own_slot_ns` (late drop'ta karenin kendi slotu; `slot_ns` o durumda önceki slot). `path` değerleri: unlocked|locked|acquire|sparse|rephase|recenter|none; `action`: pending|release|replace|move|discard|now (now = pacer'sız hemen render). `lock_slot_ns` = kare işlendikten sonraki kilit slotu; `acquire_ns` = o an taze edinim hangi slotu seçerdi; `k` = kilitli yolda yakalama farkından periyot sayısı; `bad_run` işlemden sonraki değer. Okuyucu kilit almaz, bir satır yazılırken dökülürse release alanları yarım olabilir. Satırlar yalnız `bufferFrames=adaptive` yolunda anlamlı (GL modunda renderer kullanılmıyor).
- **Test edilmeyenler / cihazda doğrulanacaklar:** Cihazda hiç çalıştırılmadı. Başlat: `adb shell am start -n dev.matebridge.client/.MainActivity --ez pace_trace true` (diğer anahtarlarla birlikte eklenebilir, örn. `--ez keep_jitter true`). Akıştan >=10 sn sonra veya uygulama arka plana alınınca dosya yazılır. Çek: `adb exec-out run-as dev.matebridge.client cat cache/pace_trace.csv > pace_trace.csv`. Kontrol: dosya var, 24 sütun, satır sayısı <= 20000, trace açıkken `ev=present` late_drops/rephase ve gecikme/kare düşüşü değişmedi.
- **Açık sorular:**
