---
id: T-342
title: İstemci — yayın ekranında fiziksel klavye tuşları klavye uygulamasından (IME) önce MateBridge'e gelsin
status: review
phase: 7
owner: android-client-dev
depends_on: []
decisions: [0003]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/
  - client-android/app/src/test/
  - backlog/tasks/T-342-client-keys-before-ime.md
---

## Amaç

2026-10-12 kullanıcı hatası: tablette varsayılan klavye SwiftKey (`com.touchtype.swiftkey`) seçiliyken HUAWEI Glide Keyboard ile Mac'e yazılamıyor; Ctrl+Shift+Esc (Android'e dön) de çalışmıyor.

Kanıt (logcat + getevent, orkestratör):
- Çekirdek ve `HwPhoneWindowManager` her tuşu görüyor (`intercept Key : 29/47/32/34 …`).
- `MB/input` istatistiklerinde `key_msgs` yalnız Enter ve Ctrl/Shift/Esc'nin bir kısmı için artıyor; harflerin hiçbiri `MainActivity.dispatchKeyEvent`'e ulaşmıyor.
- `dumpsys input_method`: `mServedView` = yayın `SurfaceView` (`app:id/video`), IME bağlı (`mBoundToMethod=true`), `mInputShown=false`.

Neden: `ViewRootImpl` tuşları `ViewPostImeInputStage`'ten (Activity.dispatchKeyEvent) **önce** `ImeInputStage` ile IME'ye verir. SwiftKey donanım klavyesi harflerini (ve kimi değiştirici tuşları) kendisi tüketip görünmez bağlantıya metin yazıyor. Huawei klavyesine geçince sorun yok; bu yalnız bir geçici çözüm.

**Girdi güvenliği:** IME bir Ctrl/Shift basışının bırakılışını yutarsa Mac'te tuş basılı kalır (AGENTS.md "input state must never get stuck"). Bu kart bunu da kapatır.

## Kapsam

1. Yayın görünürken (bağlantı paneli gizli; ayar paneli açık ya da kapalı fark etmez) fiziksel klavyenin **her** tuşu, hangi IME seçili olursa olsun, IME'den önce MateBridge'in tuş yoluna (`routeKeyEvent`) girer. Önerilen yol: bu sürede pencere IME hedefi olmasın (`WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM`), bağlantı paneli görününce kalksın; ekranda açık kalan yazılım klavyesi gizlensin. Daha iyi bir yol bulursan (ör. `dispatchKeyEventPreIme`) Plan'da gerekçesiyle yaz.
2. Bağlantı ekranındaki adres alanları (`endpointField`, `remoteField`) eskisi gibi çalışır: yazılım klavyesi açılır, fiziksel klavyeyle yazılabilir.
3. Geçişlerde yarım basış olmaz: yayın ↔ bağlantı paneli geçişinde basılı tuşlar mevcut yolla (RELEASE_ALL / KeyTracker) bırakılır. Bir tuşun basışı bir yoldan, bırakılışı öteki yoldan gidip kaybolamaz.
4. Değiştirmeyin: tuş eşlemesi, yerel kısayollar, kalem çift dokunma tuşu (718/190), ses tuşları, PROTOCOL.

## Kabul

- Birim testi: "pencere IME hedefi mi" kararını veren saf fonksiyon (yayın görünür → hayır; bağlantı paneli → evet; ayar paneli açık → hayır).
- `./scripts/check.sh` geçer.
- Cihaz testi orkestratörde (SwiftKey varsayılan iken yazma, Ctrl+Shift+Esc, Ctrl+Shift+6, bağlantı ekranında adres yazma; Huawei klavyesiyle aynı).

## Plan

- Saf karar: `ImeTarget.windowIsImeTarget(streamVisible, settingsPanelOpen)` (settings/SettingsPanelState.kt) = `!streamVisible && !settingsPanelOpen`.
- `MainActivity.syncImeTarget()`: karar degisince `FLAG_ALT_FOCUSABLE_IM` ekle (yayin/ayar paneli) ya da kaldir (baglanti paneli); eklerken yazilim klavyesi `hideSoftInputFromWindow`. Cagri yerleri: render() icinde panel.visibility sonrasi, openSettingsPanel, closeSettingsPanel.
- Neden bayrak: `dispatchKeyEventPreIme` yalniz odaktaki View icin calisir (SurfaceView odakta, ama IME zaten ImeInputStage'de once tuketir); bayrak IME asamasini tamamen atlatir ve tum IME'lerde ayni davranir.
- Tus basili kalma: basis/birakilis mevcut capture.setActive/RELEASE_ALL yolunu kullanir; deger degismedi.

## Handoff

- Commit: bkz. `git log task/T-342-keys-before-ime` (T-342 commit). Dosyalar: MainActivity.kt, settings/SettingsPanelState.kt (ImeTarget), test settings/ImeTargetTest.kt, bu kart.
- Varsayim: baglanti paneli gorunurken (adres alanlari) pencere IME hedefi; yayin ve ayar paneli acikken degil. Yayin ici ayar paneli metin alani icermiyor varsayildi.
- check.sh ALL OK. Cihazda test EDILMEDI.
- Tablette kontrol: SwiftKey varsayilan iken yayinda harf yazma, Ctrl+Shift+Esc, Ctrl+Shift+6; baglanti ekraninda adres alanina yazma (yazilim klavyesi acilir); yayin<->panel gecisinde Ctrl/Shift Mac'te basili kalmiyor; Huawei klavyesiyle ayni.

## Açık sorular
