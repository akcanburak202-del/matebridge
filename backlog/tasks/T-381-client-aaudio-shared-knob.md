---
id: T-381
title: İstemci — geliştirici anahtarı `audio_out=shared` (Düşük gecikme'de AAudio SHARED ile başla) — exclusive MMAP cızırtısı A/B
status: review
phase: 7
owner: android-client-dev
depends_on: []
decisions: [0012]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/audio/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/DevKnobs.kt
  - client-android/app/src/test/
  - docs/KNOBS.md
  - docs/LOGGING.md
  - backlog/tasks/T-381-client-aaudio-shared-knob.md
---

## Amaç

NOTES 2026-10-25 23:40: Düşük gecikme (`api=aaudio sharing=exclusive mmap=1 burst=240 buf=1440`) ~8 dk sonra cızırdamaya başlıyor, uygulama sayaçları temiz; akışı yeniden açmak (Uyumlu → Düşük gecikme) gideriyor. Hipotez: exclusive MMAP akışı uygulamaya görünmeyen bir duruma giriyor. A/B için Düşük gecikme zincirini (0012: EXCLUSIVE → SHARED → TRACK) **SHARED adımından** başlatan bir geliştirici anahtarı. Varsayılan davranış değişmez.

## Kabul

1. `--ez dev true --es audio_out shared` (mevcut `audio_out` anahtarına yeni değer; `DevKnobs.SPECS` `ids`) → AAudio önce SHARED açılır. MMAP'lı ya da MMAP'sız SHARED kabul edilir mi, mevcut SHARED gecikme denetimi (probation) uygulanır mı: Plan'da kararlaştır ve gerekçelendir; amaç ölçüm, yani anahtar açıkken SHARED akışı mümkünse korunmalı (gecikme `audio_out`/`audio_clock_raw` satırlarında görünür).
2. Anahtar yokken davranış bayt bayt aynı (mevcut testler yeşil). Panel `Ses çıkışı` seçimi değişmez; anahtar, mevcut `audio_out=aaudio` anahtarı gibi o açılış için kayıtlı seçimin yerine geçer (kayıtlı Uyumlu dahil); panelde herhangi bir `Ses çıkışı` seçimi geçersiz kılmayı bitirir. (Orkestratör 2026-10-25: Codex P2 üzerine kabul metni mevcut `aaudio` davranışına hizalandı; A/B'de kullanıcı Uyumlu'dayken anahtar doğrudan devreye girsin.)
3. `audio ev=audio_out` satırında `reason=` ile anahtarın etkisi görünür (`sharing=shared mmap=0|1`, `requested=shared`). `diag ev=dev_knobs` profil listesinde görünür.
4. Daily APK'da çalışır (geliştirici kapısı derleme türünden bağımsız).
5. Birim testleri: SinkPolicy zinciri anahtarla SHARED'dan başlar, SHARED açılamazsa TRACK'e düşer; anahtarsız zincir değişmez.
6. `docs/KNOBS.md` (`audio_out` satırı) ve gerekiyorsa `docs/LOGGING.md` güncellenir.

## Plan

- Yeni `AudioOutPref.SHARED` (id `shared`), yalnız `--es audio_out shared` ile gelir (parse "shared" -> SHARED). Panel yalnız AUTO/TRACK yazar; panelde Düşük gecikme/Uyumlu seçmek ya da mod katmanı değişimi launch override'ını zaten bitirir (`audioOutFromExtra=false`), yani Uyumlu seçilince anahtar yok sayılır.
- `SinkPolicy.next()`: pref SHARED iken EXCLUSIVE adımı atlanır; zincir SHARED -> TRACK. `reset()` sonrası da (pref'ten türetilir).
- Probation kararı: SHARED pref'te probation YOK (AAUDIO pref'iyle aynı: `onOpened` -> ACCEPT). Gerekçe: amaç ölçüm; 60 ms gecikme sınırı akışı düşürürse A/B yapılamaz. Gecikme `audio_out`/`audio_clock_raw` satırlarında görünür kalır.
- MMAP olmayan SHARED akış yine REJECT (karar 0012 Ek / T-100 M1: write zaman aşımı MMAP'sız güvenilir değil, stop takılabilir) -> TRACK; `audio_out_rejected reason=not_mmap` loglanır. SHARED açılamazsa TRACK.
- `DevKnobs.SPECS` `audio_out` ids'e `shared` (profil `knobs=audio_out:shared`). KNOBS.md ve LOGGING.md güncellenir.
- Testler: SinkPolicyTest (SHARED zinciri, açılmazsa TRACK, probationsuz, non-MMAP reject, reset, setPref), parse, DevKnobsTest.

## Handoff

- Kod commit: "T-381: audio_out=shared starts the Düşük gecikme chain at AAudio SHARED" (SHA için dalın ucu; son commit yalnız bu kart).
- Dosyalar: `audio/SinkPolicy.kt` (yeni `AudioOutPref.SHARED`), `session/DevKnobs.kt` (ids), `SinkPolicyTest`, `DevKnobsTest`, `docs/KNOBS.md`, `docs/LOGGING.md`, bu kart.
- Davranış: `--ez dev true --es audio_out shared` -> zincir SHARED -> TRACK (EXCLUSIVE hiç denenmez, rebuild/reset sonrası da). Probation yok (akış korunur). MMAP olmayan SHARED reddedilir -> Uyumlu/AudioTrack (karar 0012 Ek, `audio_out_rejected reason=not_mmap`). Panelde herhangi bir Ses çıkışı seçimi override'ı bitirir (mevcut `audioOutFromExtra` davranışı).
- Log: `audio_out_pref value=shared source=extra`, `audio_out ... requested=shared probation=0 pref=shared`, `ev=profile ... knobs=audio_out:shared`.
- Testler: hedefli + tam `:app:testDebugUnitTest` (2430 test): yalnız bilinen zamanlama testleri düştü (AacDecodeWorkerTest, DecoderWaitTest, OutputParkTest; yük altında, T-367). check.sh çalıştırılmadı (kullanıcı oyunda).
- Cihazda kontrol: `adb shell am start -n <paket>/.MainActivity --ez dev true --es audio_out shared`; logda `audio_out` satırında `sharing=shared mmap=1` ve `requested=shared` gör; mmap=0 çıkarsa Uyumlu'ya düşer (not_mmap). 10+ dk Düşük gecikme'de cızırtı olup olmadığına bak.

## Open questions

- Yok. (MMAP'sız SHARED'ı A/B için kabul etmek 0012 Ek'ini gevşetmek olur; yapılmadı.)
