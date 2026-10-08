---
id: T-317
title: Tablet — dec_out_park varsayılanı on (T-312 A/B kabul); off bir döngü geri dönüş
status: done
phase: 7
owner: android-client-dev
depends_on: [T-312]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/DevKnobs.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - backlog/tasks/T-317-dec-out-park-default.md
---

## Amaç

T-312 cihaz A/B'si (2026-10-08, 10 fps sahnesi, 3 çift, debug APK):
- uyanma 1.175 → 842/s (−%28);
- CPU %29,6 → %27,4;
- `cap_dec` p50 21,2 / 20,7 ms, p95 33,0 / 32,0 ms (bedel yok).

Hareket sahnesinde fark yok (beklenen).

## Kabul

1. Varsayılan `on`. `--es dec_out_park off` bir döngü boyunca geri dönüş olarak kalır; kod yorumunda "sonra kaldırılır" yazar.
2. `ev=profile knobs=` yalnız `dec_out_park:off` gösterir. Testler yeni varsayılana göre güncellenir.
3. Önerilen KNOBS metnini Handoff'a yaz.

## Plan

`DevKnobs.decOutPark` varsayılan true, parse `!= "off"`; `VideoRenderer.outPark` varsayılan true; testler güncellenir. Knob debug-only kalır (off yalnız dev ile).

## Handoff

- Commit: bkz. `git log task/T-317-out-park-default -1`. check.sh: ALL OK.
- Dosyalar: DevKnobs.kt, VideoRenderer.kt, OutputPark.kt (yorum), DevKnobsTest.kt, bu kart.
- Not: bilinmeyen değer artık varsayılan olan on'a düşer. `off` yalnız `--ez dev true` ile geçerli (knob debug-only). Yorumlarda "sonra kaldırılır" yazıyor.
- Tablette kontrol: varsayılan açılışta `ev=profile knobs=-`; `--ez dev true --es dec_out_park off` ile `knobs=dec_out_park:off` ve uyanma sayısının ~1.175/s'e dönmesi; normal akışta cap_dec p50 ~21 ms.
- Önerilen KNOBS metni: `dec_out_park` artık varsayılan `on`; `--es dec_out_park off` (dev ile) bir döngü boyunca eski 5 ms poll'a geri dönüş, sonra kaldırılır. `ev=profile knobs=` yalnız `dec_out_park:off` iken bu girdiyi gösterir.

- Codex P3 fix: `knobs=` lists `dec_out_park` only for an effective `off` (explicit on and unknown values are absent); tests assert this.

## Open questions
