---
id: T-387
title: İstemci — oyun çözünürlüğü seçenekleri tabletin doğal boyutundan (oranla) hesaplanır
status: review
phase: 7
owner: android-client-dev
depends_on: [T-215, T-223, T-245]
decisions: [0029, 0030]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/
  - client-android/app/src/main/kotlin/dev/matebridge/client/settings/SettingsCatalog.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/Settings.kt
  - client-android/app/src/test/
  - backlog/tasks/T-387-client-game-resolution-from-native.md
---

## Amaç

Karar 0029 eki 2026-10-28. `GameResolution` bugün MatePad'e (2800×1840) göre sabit beş boyut. Xiaomi Pad Mini (3008×1880, en-boy 1,60) için bu boyutların en-boy oranı host kuralına (`host-mac/Sources/MateBridgeCore/Video/GameDisplayPolicy.swift`, PROTOCOL §0x05 "Oyun ekranı") uymuyor. Seçenekler tabletin kendi doğal piksel boyutundan (HELLO'da gönderilen W×H) hesaplanmalı.

## Kabul

1. Seçenekler: doğal boyutun %50, %66, %75, %80, %100'ü. `w` = `W·oran`'a en yakın çift; `h` = `w·H/W`'ye en yakın çift; sonuç host kuralını (çift, `W/2 ≤ w ≤ W`, `H/2 ≤ h ≤ H`, `|w·H − h·W| ≤ 0,005·h·W`) sağlamıyorsa kurala uyan en yakın çift değere çekilir. %100 "(deneysel)" etiketini korur. Varsayılan %66.
2. MatePad 2800×1840 için çıkan boyutlar, etiketler, toast/overlay metinleri ve `STREAM_PREFS` içeriği bugünküyle **aynı** (1400×920, 1848×1214, 2100×1380, 2240×1472, 2800×1840). Mevcut testler (SettingsCatalogTest, StreamModeTest, GameModeTest, AutoBitrateLayerTest, FixtureTest) MatePad boyutuyla değişmeden geçer; gerekiyorsa yalnız yeni API'ye uyarlanır, beklenen değerler değişmez.
3. Xiaomi 3008×1880: 1504×940, 1986×1242, 2256×1410, 2406×1504, 3008×1880. Birim testi: bu iki cihaz ve birkaç keyfi boyut (ör. 2560×1600, 2000×1200, tek sayılı bir kenar) için her seçenek host kuralını sağlar.
4. Kayıtlı tercih oran adımı olarak saklanır. Eski kayıtlı değerler (`1400x920`, `1848x1214`, `2100x1380`, `2240x1472`, `2800x1840`) karşılık gelen adıma eşlenir; bilinmeyen değer varsayılana düşer. Göç testi var.
5. Doğal boyut, HELLO'da gönderilen değerle aynı kaynaktan gelir (iki ayrı hesap olmasın). Panel bağlanmadan önce de doğru etiketi gösterir.
6. `GameResolution.appliedIn` mantığı (tam geometri kontrolü) yeni boyutlarla çalışır.
7. Protokol, host, fixture değişmez. `./scripts/check.sh` geçer.

## Plan

1. `GameResolution` enum = oran adımları (P50/P66/P75/P80/P100, id "50".."100", `legacyId` = eski `WxH`); `GameDisplay(step, w, h)` = adımın tabletin `NativeSize`'ına göre çözülmüş hali (label, panelLabel, appliedIn). Hesap: w=en yakın çift(W·oran), h=en yakın çift(w·H/W), host kuralına (`accepts` aynası) uymazsa en yakın kabul edilen çifte arama.
2. `GameModeSettings(native = NativeSize)`; `display(mode)` `GameDisplay?` döner. MainActivity tek `nativeSize` (lazy, getRealMetrics) hem HELLO'yu hem GameModeSettings'i besler; panel etiketi `gameResolutionLabel(r)` ile dinamik.
3. Testler MatePad değerleriyle aynı beklentilerle uyarlanır; Xiaomi, keyfi boyutlar, göç testleri eklenir.

## Handoff

- Commit: son T-387 commit'i (task/T-387-game-resolution-native).
- Dosyalar: stream/GameResolution.kt (enum adımlar P50..P100 + `NativeSize` + `GameDisplay`), stream/GameMode.kt (`native` parametresi, `display()` -> `GameDisplay?`), stream/StreamMode.kt (toastText tipi), settings/SettingsCatalog.kt (`gameResolutionLabel`), session/Settings.kt (yalnız yorum), MainActivity.kt (bkz. Open questions); testler: GameResolutionTest, SettingsCatalogTest, SettingsResetTest, StreamModeTest.
- Saklama: oran adımı id'si "50|66|75|80|100"; eski `WxH` değerleri `legacyId` ile eşlenir, bilinmeyen -> %66 (testli).
- MatePad değerleri/etiketleri/STREAM_PREFS aynı (test beklentileri değişmedi). Xiaomi 3008x1880 -> 1504x940, 1986x1242, 2256x1410, 2406x1504, 3008x1880 (testli). Keyfi boyutlar (2560x1600, 2000x1200, 2801x1841, 2800x1839, 1920x1080, 1280x800, 2961x1848) host kuralını sağlar.
- check.sh: gradle yalnız T-367'deki bilinen zamanlama testlerinde kırmızı (DecoderWaitTest, OutputParkTest; ilk koşuda ayrıca AacDecodeWorkerTest ve bir swift host testi, paralel ajan yükü altında); diğer tüm testler geçti. Kod bu testlere dokunmuyor. Tam yeşil check.sh alınamadı.
- Tablette kontrol: MatePad'de Oyun çözünürlüğü paneli eskisiyle aynı 5 etiketi göstermeli (son "2800×1840 (deneysel)"), varsayılan 1848×1214, eski kayıtlı seçim korunmalı; Xiaomi'de bağlanmadan önce de 1986×1242 vb. etiketler, bağlanınca `game_display=applied`.

## Open questions

- `MainActivity.kt` kartın `files:` listesinde yok, ama HELLO ve oyun çözünürlüklerinin tek kaynaktan beslenmesi (kabul 5) ve SettingsHost uygulaması için dokunuldu (lazy `nativeSize`, `gameResolutionLabel`, `native =`). Orchestrator onaylasın.
