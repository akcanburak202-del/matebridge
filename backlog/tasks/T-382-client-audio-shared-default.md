---
id: T-382
title: İstemci — Düşük gecikme varsayılanı shared MMAP; panelde "Düşük gecikme (eski)" (exclusive zinciri)
status: done
phase: 7
owner: android-client-dev
depends_on: [T-381]
decisions: [0012]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/audio/
  - client-android/app/src/main/kotlin/dev/matebridge/client/settings/SettingsCatalog.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/Settings.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/DevKnobs.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/GameMode.kt
  - client-android/app/src/test/
  - docs/KNOBS.md
  - docs/LOGGING.md
  - backlog/tasks/T-382-client-audio-shared-default.md
---

## Amaç

Karar 0012 eki (2026-10-27): exclusive MMAP ~8 dk sonra cızırdıyor, shared MMAP 42 dk temiz (T-381, NOTES 2026-10-26 18:15). Düşük gecikme'nin varsayılanı shared olur; kullanıcı panelden tek dokunuşla eski exclusive zincirine dönebilir.

## Kabul

1. Panel "Ses çıkışı" üç seçenek, bu sırayla: **Düşük gecikme** (kayıtlı `auto`), **Düşük gecikme (eski)** (kayıtlı `exclusive`), **Uyumlu** (kayıtlı `track`). Seçili gösterim üçünü de doğru yansıtır (bugünkü "TRACK değilse AUTO" eşlemesi düzeltilir). Bir launch override'ı (`aaudio`/`shared`) gösterimde en yakın seçenek olarak görünebilir; Plan'da yaz.
2. `auto` zinciri: AAudio SHARED (yalnız MMAP) → AudioTrack. EXCLUSIVE denenmez, probation yok. Bu, T-381'deki `shared` davranışının aynısıdır.
3. `exclusive` zinciri: bu karttan önceki `auto` zinciri birebir (EXCLUSIVE → probation'lı SHARED → AudioTrack). Mevcut AUTO testleri bu tercihe taşınır ve yeşil kalır.
4. Kayıtlı `auto` olan kurulumlar yeni varsayılana geçer, geçiş kodu yok. Bilinmeyen kayıtlı değer → `auto` (bugünkü gibi).
5. Launch extra: `--es audio_out exclusive` eklenir. `shared` geriye uyumlu kalır (`auto` ile aynı zincir; ayrı enum değeri tutmak ya da takma ad yapmak Plan'da). `aaudio`, `track`, `auto` değişmez. `DevKnobs.SPECS` ids güncellenir.
6. Oyun modu katmanı Düşük gecikme'ye (`auto`) geçirmeye devam eder. Oyun modundayken panelde "Düşük gecikme (eski)" seçmek mevcut katman kuralıyla saklanır (Uyumlu seçimi nasıl davranıyorsa öyle).
7. Loglar: `audio_out_pref value=exclusive|auto ...`, `audio_out ... requested=shared|exclusive` doğru. `docs/KNOBS.md`, `docs/LOGGING.md` güncellenir.
8. Birim testleri: SinkPolicy (auto: SHARED→TRACK, EXCLUSIVE yok, probation yok, non-MMAP reject; exclusive: eski zincir), parse/resolve, panel seçimi ve gösterimi (SettingsCatalogTest), Settings okuma/yazma, GameMode.

## Plan

- `AudioOutPref`: yeni `EXCLUSIVE` degeri (`exclusive`); `SHARED` enum degeri kalkar, `parse("shared")` -> `AUTO` (takma ad, ayri deger yok). `AUTO` artik T-381 shared zinciri; `EXCLUSIVE` eski AUTO zinciri.
- `SinkPolicy`: EXCLUSIVE adimi yalniz `EXCLUSIVE`/`AAUDIO` tercihinde denenir; probation yalniz `EXCLUSIVE` tercihinde. AAUDIO, TRACK degismez.
- Panel: uc secenek (auto / exclusive / track), gosterim `exclusive`->exclusive, `track`->track, digeri auto. Launch override'i (`aaudio`) panelde gosterilmez (panel kayitli degeri gosterir, bugunku gibi); `shared` = auto zaten.
- `GameMode` Oyun katmani `AUTO` olarak kalir (artik shared); panelde "eski" secilirse mevcut AUDIO override kuralıyla katmanda saklanir.
- `Settings`: kayitli `exclusive` okunur/yazilir; bilinmeyen -> auto. `DevKnobs.SPECS` ids'e `exclusive`. KNOBS/LOGGING guncellenir.
- Testler: SinkPolicyTest (eski AUTO testleri EXCLUSIVE'e, SHARED testleri AUTO'ya), AudioOutSettingTest, SettingsCatalogTest, GameModeTest, DevKnobsTest.


## Handoff

- Commit: (branch tip, bkz. rapor) `task/T-382-audio-shared-default`, taban main db053c3f.
- Dosyalar: audio/SinkPolicy.kt (enum + zincir), audio/AudioPlayout.kt (yalniz yorum), settings/SettingsCatalog.kt (uc secenek), session/DevKnobs.kt (ids: `exclusive`), docs/KNOBS.md, docs/LOGGING.md, testler (SinkPolicyTest, SettingsCatalogTest, GameModeTest, DevKnobsTest, AudioOutSettingTest). `Settings.kt`, `GameMode.kt` kod degisikligi gerekmedi (parse/AUTO zaten dogru).
- Varsayimlar: `SHARED` enum degeri kaldirildi; `shared` yalniz `parse` takma adi (-> AUTO), `AUTO.id` = `auto` (loglarda `shared` artik gorunmez; `requested=shared` choice logName'inden gelmeye devam eder). Launch override `aaudio` panelde "Düşük gecikme" gorunur (bugunku gibi; panel kayitli degeri yansitir). Kayitli `shared` (hic yazilmadi) -> auto.
- check.sh: ALL OK (client gradle testleri gecti, flaky T-367 hatasi gorulmedi).
- Cihazda kontrol: (1) Panel Ses çıkışı: Düşük gecikme / Düşük gecikme (eski) / Uyumlu, secim kalicilik; (2) varsayilanda logda `audio_out ... requested=shared`, `probation=0`, `dumpsys media.aaudio` SHARED MMAP; (3) "eski" secilince `requested=exclusive` ve `pref=exclusive`; (4) `--es dev true --es audio_out exclusive` calisir; (5) Oyun modunda "eski" secimi katmanda kalir, cikinca eski ayara doner.

## Open questions
