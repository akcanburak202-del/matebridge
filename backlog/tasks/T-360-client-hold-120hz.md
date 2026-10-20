---
id: T-360
title: İstemci — "Kumandayla 120 Hz" (erişilebilirlik servisiyle basılı sahte dokunma, varsayılan kapalı)
status: review
phase: 7
owner: android-client-dev
depends_on: [T-350]
decisions: [0041, 0016]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/
  - client-android/app/src/main/res/
  - client-android/app/src/main/AndroidManifest.xml
  - client-android/app/src/test/
  - docs/KNOBS.md
  - backlog/tasks/T-360-client-hold-120hz.md
---

## Amaç

Karar 0041: kumanda ya da klavyeyle Oyun 120'de panel 60 Hz'te kalıyor. Basılı tutulan sahte bir dokunma paneli 120'de tutuyor (NOTES 2026-10-20 ~22:00, adb ile kanıtlandı). Bunu adb'siz, istemcinin kendi erişilebilirlik servisiyle yap; dokunma Mac'e asla gitmesin.

## Kapsam

1. **Servis:** `AccessibilityService` (ör. `input/HoldTouchService.kt`), manifestte `BIND_ACCESSIBILITY_SERVICE` ile; XML yapılandırma: `canPerformGestures=true`, `canRetrieveWindowContent=false`, olay türü yok (ya da en dar), Türkçe açıklama ("MateBridge, kumandayla oynarken tablet ekranını 120 Hz'te tutmak için görünmez bir dokunma kullanır. Ekran içeriğini okumaz."). Servis kendi başına hiçbir şey yapmaz; istemci ona "tut / bırak" der (süreç içi, ör. statik `StateFlow`/dinleyici).
2. **Hedef pencere:** servis bağlanınca ekranın bir köşesine yakın (kenar jestlerinden uzak, ör. kenarlardan 48 px içeride) küçük bir `TYPE_ACCESSIBILITY_OVERLAY` penceresi ekler (ör. 16×16 px, şeffaf, dokunmayı tüketen bir View). Basılı dokunma bu pencerenin ortasına yapılır. Pencere yalnız tutarken eklenir, bırakınca kaldırılır.
3. **Tutma:** `dispatchGesture` + `GestureDescription.StrokeDescription(path, 0, D, willContinue=true)`; süre dolmadan `continueStroke` ile zincirle (D ör. 10 s, sınır `getMaxGestureDuration`). Bırakırken `willContinue=false` ile kısa bir son parça gönder (UP). `onCancelled` (gerçek dokunma iptal etti) → koşullar hâlâ tutuyorsa 1 sn sonra yeniden başlat; art arda hızlı iptallerde geri çekil (ör. en çok 1/sn).
4. **Yedek (yalnız 2. adım AGP'yi tetiklemezse, cihaz testinde orkestratör karar verir):** overlay yok, dokunma video yüzeyine; istemci `MainActivity` girişinde bu dokunmayı tanıyıp (ör. `MotionEvent` kaynağı/cihaz kimliği/bayrak, ya da sabit koordinat + aktif tutma durumu) Mac'e göndermeden atar. Bu yolu iskelet olarak hazırla ama varsayılan olarak 2. adımı kullan; seçim bir dev düğmesi (`hold120_target=overlay|surface`, KNOBS'ta).
5. **Ayar ve panel:** `Settings.hold120` (varsayılan **false**, USER_KEYS'te). Panelde Oyun'a ait yerde (ya da Görüntü bölümünde "Performans artışı"nın yanında) Toggle "Kumandayla 120 Hz: Açık/Kapalı" + not "Oyun 120'de ekranı 120 Hz'te tutar, pil tüketimi artar". Servis etkin değilse not yerine "Erişilebilirlik izni gerekli" + `Settings.ACTION_ACCESSIBILITY_SETTINGS` açan düğme. Uzak oturumda gizli.
6. **Koşullar** (hepsi gerekli; biri düşünce anında bırak): anahtar açık, servis bağlı, video akıyor, uygulama ön planda (onStop'ta bırak), uzak oturum değil, mod Oyun ve akış fps 120. Ayar ya da mod değişince yeniden bağlanmadan anında başla/bırak. Bağlantı kopması, arka plan, servis kapanması → bırak.
7. **Girdi güvenliği (AGENTS.md):** sahte dokunma hiçbir yolda Mac'e işaretçi/dokunma olarak gitmemeli; gerçek dokunmalar etkilenmemeli (tek parmak tıklama, pinch, kalem). Sahte dokunma takılı kalmamalı: her bırakma yolunda UP gönderildiğini testle göster.
8. **Günlük:** `ev=hold120 state=on|off reason=setting|stream|background|remote|mode|service|cancelled` (durum değişiminde bir satır, her zincir parçasında değil). `docs/KNOBS.md`'ye panel ayarı ve dev düğmesi.
9. Tel biçimi ve host değişmez.

## Kabul

- Birim testleri: varsayılan kapalı; koşullar tamam → tut; her koşul düşünce bırak (UP); iptalde geri çekilmeli yeniden deneme; Oyun dışı ya da 60 fps'te tutmaz; uzak oturumda tutmaz; kapalıyken servis/pencere/zamanlayıcı işi yok.
- `./scripts/check.sh` geçer.
- Cihaz testi orkestratörde (Handoff'a adımları yaz): servis izni açılır; Oyun 120 + dokunmadan panel `dumpsys SurfaceFlinger` "Current mode" 120'de kalır, host `display_rate hz=120`; host logunda sahte dokunmadan işaretçi olayı yok (`input_age pointer_n` dokunmazken 0); gerçek dokunma/pinch/kalem normal; anahtar kapat, arka plana al, Oyun 60'a geç → panel 60'a döner.

## Plan

1. Saf mantık `input/Hold120.kt`: `Hold120Rules` (koşul fonksiyonu), `Hold120Controller` (tut/bırak durumu, iptalde 1 sn geri çekilmeli yeniden deneme, kenar-tetikli günlük) — Android bağımlılığı yok, `Hold120Actuator` arayüzü (start/stop) ve `Scheduler` arayüzü ile test edilir.
2. `input/HoldTouchService.kt`: AccessibilityService; `TYPE_ACCESSIBILITY_OVERLAY` 16x16 pencere (köşeden 48 px içeride), `dispatchGesture` + `continueStroke` zinciri (10 s), bırakınca willContinue=false son parça. Süreç içi `HoldTouchService.instance` ile actuator.
3. Manifest servis kaydı + `res/xml/hold_touch_service.xml` + Türkçe açıklama string.
4. `Settings.hold120` (varsayılan false, USER_KEYS), `hold120_target` dev düğmesi; panel Toggle + izin notu/düğmesi (SettingsCatalog), uzak oturumda gizli.
5. MainActivity: PerfBoost gibi `hold120.update(...)` çağrıları (ayar, mod, fps, ön plan, uzak, servis bağlı), onStop/disconnect'te bırak, shutdown.
6. Yedek `surface` hedefi: iskelet (Hold120Target enum + MainActivity'de atma kancası yok sayılırsa varsayılan overlay); KNOBS güncellenir.
7. Birim testleri: kurallar, controller, katalog.

## Handoff

- Commit: bkz. dal `task/T-360-hold-120hz` son commit (SHA orkestratör mesajında).
- Dosyalar: `input/Hold120.kt` (kurallar, controller, arayüzler), `input/HoldTouchService.kt` (servis + actuator + overlay), `res/xml/hold_touch_service.xml`, manifest, strings, `Settings.hold120`, `DevKnobs.hold120Target`, `SettingsCatalog` (anahtar, not, "Erişilebilirlik ayarlarını aç" düğmesi), `MainActivity` (syncHold120, PerfBoost'un yanında), testler (`Hold120Test`, katalog, DevKnobs), `docs/KNOBS.md`.
- Varsayımlar: overlay 16x16 px, sol üstten 48 px içeride, dokunma ortasında; zincir 10 s (getMaxGestureDuration ile sınırlı), UP = 50 ms'lik willContinue=false son parça. Geri çekilme 1/2/4/8 sn, 5 sn dayanan tutuş sayacı sıfırlar. Servis "bağlı" = `HoldTouchService.instance != null`. Mod/fps: `streamMode.isGame` ve `streamConfig.fps >= 120`.
- `surface` yedek yolu uygulanmadı: `hold120_target` yalnız ayrıştırılıyor/KNOBS'ta, bugün overlay gibi davranıyor (kapsam 4 "iskelet"; AGP overlay'i saymazsa orkestratör kararıyla ayrı iş).
- check.sh: Android derlemesi ve yeni testler geçti. check.sh FAIL veriyor, ama yalnız temel dalda da (HEAD~1) yeniden üretilen, makine yüküne bağlı zamanlama testleri yüzünden: `DecoderWaitTest.inputParksWith...`, `OutputParkTest.withParkOff...` (+ ara sıra `AacDecodeWorkerTest.lateOutput...`) ve Swift `BoundedWaitTests` (host-mac'e dokunulmadı).
- Test EDİLMEDİ (cihaz): servisin gerçekten bağlanması, overlay'in AGP'yi 120'de tutması, continueStroke zincirinin 10 s sınırında kesintisiz sürmesi, gerçek dokunmanın tutuşu iptal edip geri gelmesi.
- Cihazda kontrol: (1) Ayarlar > Erişilebilirlik'ten "MateBridge 120 Hz" servisini aç; panelde "Kumandayla 120 Hz" Açık. (2) Oyun 120, dokunmadan: `dumpsys SurfaceFlinger` Current mode 120'de kalır, host `display_rate hz=120`. (3) Host logunda sahte dokunmadan işaretçi olayı yok (`input_age pointer_n` dokunmazken 0). (4) Gerçek tek parmak tıklama, pinch, kalem normal; gerçek dokunma sonrası ~1 sn içinde `ev=hold120 state=off reason=cancelled` sonra `state=on`. (5) Anahtarı kapat / arka plana al / Oyun 60'a geç / uzak oturum: `state=off reason=setting|background|mode|remote`, panel 60'a döner; servis izni yokken panelde "Erişilebilirlik izni gerekli" + düğme.

## Open questions
