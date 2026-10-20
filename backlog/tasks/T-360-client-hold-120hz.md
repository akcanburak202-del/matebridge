---
id: T-360
title: İstemci — "Kumandayla 120 Hz" (erişilebilirlik servisiyle basılı sahte dokunma, varsayılan kapalı)
status: todo
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

(boş — ajan yazar)

## Handoff

## Open questions
