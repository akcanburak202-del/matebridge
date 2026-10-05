---
id: T-245
title: Client — experimental "2800×1840 (deneysel)" game resolution, offered only in Oyun 60
status: review
phase: 6
owner: android-client-dev
depends_on: []
decisions: [0029, 0030]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/
  - client-android/app/src/main/kotlin/dev/matebridge/client/settings/
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - docs/decisions/0030-modes-daily-drawing-game.md
  - backlog/tasks/T-245-client-game-native-2800-option.md
---

## Amaç

Kullanıcı 2026-10-05: Oyun modunda daha yüksek çözünürlük. Ölçüm (NOTES 2026-10-05 ~14:30): Oyun 60'ta 2800×1840 çözme 13,8–14,2 ms (60 fps bütçesinin ~%85'i), SDR akıcı, HDR'de sunum atlaması daha fazla (Wi-Fi'de ölçüldü). Kullanıcı deneysel seçenek istedi.

## Bağlam

- Bugün oyun çözünürlüğü seçenekleri 1848×1214 ve 2240×1472 (0030; prefs `game_resolution`). Yeni seçenek "2800×1840 (deneysel)": STREAM_PREFS `display_*` = 2800×1840 (host 0029 doğrulaması `w ≤ screen_width` ile kabul eder; 1x ekran = noktalar pikseller, oyunlar için).
- **Yalnız Oyun 60'ta** gösterilir/geçerlidir. Oyun 120'ye geçince ya da 120 seçiliyken 2800 seçimi etkin olarak 2240×1472'ye düşer (kayıtlı seçim korunur, 60'a dönünce geri gelir); panelde satır 120'de gri "(yalnız 60 fps)".
- Host değişikliği yok (önce doğrula: 0029 kuralları 2800×1840'ı kabul ediyor mu, `game_display_failed` riski var mı; host kodunu okuyup Handoff'a yaz, gerekiyorsa Açık sorular).
- 0030'a kısa ek (deneysel seçenek, yalnız Oyun 60) — karar dosyası `files:` içinde, metni ajan önerir.

## Kabul kriterleri

- [x] [JVM] Seçenek listesi fps'e göre; 120'de etkin çözünürlük 2240 düşüşü; kayıtlı seçim korunur; STREAM_PREFS `display_*` doğru.
- [x] [JVM] Panel satırı etiketi ve gri durumu.
- [x] `./scripts/check.sh` geçer. APK kurma/adb yok.

## Plan

1. `stream/GameResolution.kt`: yeni giriş `R2800("2800x1840", 2800, 1840)`, `experimental = true`. Saf yardımcılar:
   `availableAt(fps)` (deneysel olan yalnız 60'ta), `effectiveAt(fps)` (120'de `R2240`'a düşer), `panelLabel(gameFps: Int?)`
   ("2800×1840 (deneysel)" / 120'de "2800×1840 (yalnız 60 fps)" / Oyun dışı, Oyun fps'i bilinmezken "2800×1840 (deneysel, yalnız 60 fps)"),
   `panelSelected(stored, gameFps)` (Oyun 120'de etkin 2240 seçili görünür). `parse("2800x1840")` artık R2800.
2. `stream/GameMode.kt`: `display(mode)` kayıtlı seçimi Oyun'un kare hızına göre etkin boyuta çevirir (STREAM_PREFS, toast,
   profile log hepsi buradan okur; kayıtlı seçim değişmez). `selectGameResolution` etkin boyut değişmediyse null döner.
   60↔120 geçişinde `selectFrameRate` zaten tam STREAM_PREFS gönderir → `fps` ve `display_*` tek mesajda değişir.
3. `settings/SettingsCatalog.kt`: `SettingItem.Option`'a seçenek başına `enabled` (varsayılan true); oyun çözünürlüğü
   satırında etiket/gri durum/seçili id yukarıdaki saf fonksiyonlardan; gri seçeneğe dokunma hiçbir şey yapmaz.
   `settings/SettingsViews.kt`: buton `isEnabled`/alpha = satır && seçenek.
4. MainActivity'ye dokunulmaz (kapsam dışı): panel Oyun dışında Oyun'un kare hızını bilmez → orada etiket iki koşulu birden yazar.
5. JVM testleri: GameResolutionTest, SettingsCatalogTest (+ gerekiyorsa StreamModeTest). 0030'a kısa ek.
6. Host doğrulaması (kod okuma): `GameDisplayPolicy.accepts` 2800×1840'ı kabul eder; Handoff'a yazılır.

## Handoff

- **Commit:** `8f762ad` (uygulama; plan `f9cd5ae`), dal `task/T-245-game-2800`. `./scripts/check.sh`: ALL OK.
- **Dosyalar:** `stream/GameResolution.kt` (R2800, `availableAt`/`effectiveAt`/`panelLabel`, `panelEnabled`/`panelSelected`),
  `stream/GameMode.kt` (`display()` etkin boyut; `selectGameResolution` yalnız etkin boyut değişince STREAM_PREFS döner),
  `settings/SettingsCatalog.kt` (`SettingItem.Option.enabled`, `gameFps(h)`, oyun çözünürlüğü satırı),
  `settings/SettingsViews.kt` (düğme başına gri), testler `GameResolutionTest`, `SettingsCatalogTest`; 0030'a ek.
- **Kabul:** [x] JVM seçenek/etkin boyut/kayıtlı seçim/STREAM_PREFS (`display_*` 2800×1840 = 12 bayt, u16 LE F0 0A 30 07);
  [x] JVM panel etiketi ve gri durum; [x] check.sh.
- **Host doğrulaması (kod okuma, değişiklik yok):** `GameDisplayPolicy.accepts` (MateBridgeCore/Video/GameDisplayPolicy.swift):
  çift, `native/2 ≤ w ≤ native`, en-boy farkı 0 → 2800×1840 **kabul**. `VirtualDisplay` 1x'te modu piksel boyutuyla kurar,
  `maxPixels` zaten 2800×1840 → yeni sınır yok. Doğal ekran `2800x1840@2x`, oyun ekranı `2800x1840@1x`:
  `DisplayMode.sameKind` HiDPI'yi karşılaştırdığı için `mode_change` ile yeniden kurulur (2240 ile aynı yol).
  `game_display_failed` riski 2240 ile aynı sınıfta (1x kurulamazsa host bir kez doğal ekrana döner); 2800 1x hiç denenmedi.
- **Varsayımlar:**
  - Oyun 120'de panel etkin **2240×1472**'yi seçili gösterir (gri 2800 değil); gri düğmeye dokunma hiçbir şey yapmaz.
  - MainActivity kapsam dışı olduğundan panel Oyun dışında Oyun'un kare hızını bilmez: orada etiket
    "2800×1840 (deneysel, yalnız 60 fps)" ve seçilebilir; uygulanması sonraki Oyun girişinde kurala göre.
  - Toast ve `ev=profile display=`/`display_applied` `GameModeSettings.display()` üzerinden etkin boyutu gösterir (MainActivity değişmeden).
  - `selectGameResolution` artık aynı etkin boyut yeniden seçilince STREAM_PREFS göndermez (önceden gönderiyordu; host için zararsızdı).
- **Test edilmedi (tablet gerekli):**
  1. Oyun 60 → panelde "2800×1840 (deneysel)" seç: Mac'te `display_recreate reason=mode_change ...->2800x1840@1x`, tablette
     `stream_config 2800x1840` ve `ev=profile display=2800x1840 display_applied=1`; `game_display_failed` yok.
  2. Oyun içinde Kare hızı 120: tek STREAM_PREFS, ekran bir kez yeniden kurulur → `2240x1472`; toast/overlay 2240; panelde
     2800 düğmesi gri "(yalnız 60 fps)", 2240 seçili. 60'a dön → 2800×1840 geri gelir.
  3. Günlük → Oyun (Oyun 60, 2800 kayıtlı) girişte doğrudan 2800×1840; Oyun → Günlük doğal `2800x1840@2x`'e döner.
  4. 2800 1x'te `dec_p50_us` (~14 ms beklenir), atlanan kare, SDR/HDR; dokunma/kalem/trackpad koordinatları doğru
     (nokta boyutu 2800×1840: trackpad/kaydırma hızı 2240'tan biraz farklı hissedilebilir).
  5. Varsayılanlara dön → 1848×1214.

### Açık sorular

- İsteğe bağlı: MainActivity'ye `SettingsHost`'a bir "Oyun kare hızı" alanı eklenirse Günlük/Çizim'de de etiket kesin
  ("(deneysel)" / gri) olabilir; bu kartın `files:` kapsamı dışında bırakıldı.
