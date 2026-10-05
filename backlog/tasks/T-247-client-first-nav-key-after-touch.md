---
id: T-247
title: Client — verify (and fix) that the first navigation key after a touch is not swallowed by ViewRootImpl leaving touch mode
status: review
phase: 6
owner: android-client-dev
depends_on: []
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/input/
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - docs/LOGGING.md
  - backlog/tasks/T-247-client-first-nav-key-after-touch.md
---

## Amaç

Araştırma (2026-10-05, siyah kalkması raporu, yan bulgu, kaynaktan; cihazda ölçülmedi): Android 12 `ViewRootImpl.EarlyPostImeInputStage.checkForLeavingTouchModeAndConsume`, dokunma kipindeyken gelen ilk gezinme tuşunun (oklar, Tab, Space, Enter, PageUp/Down, Home/End) KEY_DOWN'ını tüketiyor; `Activity.dispatchKeyEvent`'e ulaşmıyor ama KEY_UP ulaşıyor. Sonuç: kalem/parmak dokunuşundan sonraki ilk Space/ok tuşu Mac'e gitmeyebilir; yalnız UP giderse host tarafında eşleşmeyen up (zararsız ama tuş kaybı).

## Bağlam

- Önce doğrula: istemcinin tuş yolu (`dispatchKeyEvent` / `onKeyDown` / `KeyTracker`) bu aşamadan önce mi sonra mı yakalıyor? Kaynak okuması + Handoff'ta sonuç.
- Gerekirse düzeltme: fiziksel klavye tuşlarını IME öncesi aşamada yakala (`View.dispatchKeyEventPreIme` odaklı görünümde, ya da pencere geri çağrısı), yalnız fiziksel klavye kaynakları (`InputDevice.SOURCE_KEYBOARD`, sanal değil). Input state never stuck: down/up eşleşmesi korunur, tekrar gönderim yok.
- Log: tutarsızlık için `ev=key_orphan_up keycode=<yalnız debug>` gibi bir sayaç (karakter yok, LOGGING kuralı).

## Kabul kriterleri

- [x] Handoff'ta kaynak analizi: sorun bu istemcide var mı.
- [ ] Varsa: [JVM] yakalama yolunun tek seferlik ve eşleşmeli olduğu testleri; `./scripts/check.sh` geçer.
- [ ] [device, orkestratör] dokunuştan sonra ilk Space/ok tuşunun Mac'te göründüğü (host `ev=` tuş sayacı).

## Plan

1. Kaynak analizi (kod yok): AOSP `android12-release` `ViewRootImpl` (`EarlyPostImeInputStage.processKeyEvent` → `checkForLeavingTouchModeAndConsume` → `ensureTouchMode(false)` → `leaveTouchMode`) ile istemcinin tuş yolunu (`MainActivity.dispatchKeyEvent` → `routeKeyEvent` → `InputCapture.onKey` → `KeyTracker`) ve odak kurulumunu (`video` SurfaceView, `syncPointerCapture`) karşılaştır.
2. Yutma yalnızca dokunma kipinde, odak yokken (ya da odak `FOCUS_AFTER_DESCENDANTS` bir ViewGroup'tayken) ve `restoreDefaultFocus()` yeni odak yerleştirdiğinde olur. Akış sırasında bu koşulun oluşup oluşmadığını tüm odak yollarında kontrol et.
3. Sorun varsa: `video` odağını garanti eden yalıtılmış bir koruma (ör. `ViewTreeObserver.OnTouchModeChangeListener`, `leaveTouchMode`'dan önce çağrılır) + JVM testli saf karar sınıfı. Sorun yoksa: kod değişikliği yok; sonuç ve cihaz kontrolü Handoff'a.

## Handoff

**Sonuç: bu istemcide sorun yok; kod değişikliği yapılmadı** (talimat: yalnız sorun varsa düzelt). `./scripts/check.sh` ALL OK (değişiklik yok, yalnız kart).

- Commit: plan `c869a9d`, handoff bu commit (`T-247: source analysis, no fix needed`). Dokunulan dosya: yalnız bu kart.

### Kaynak analizi (AOSP `android12-release`, API 31)

1. Sıra: `ViewPreImeInputStage` → `ImeInputStage` → **`EarlyPostImeInputStage`** → `NativePostIme` → `ViewPostImeInputStage` (`DecorView` → `Activity.dispatchKeyEvent`). İstemcinin tüm tuş yolu `Activity.dispatchKeyEvent` → `routeKeyEvent` → `InputCapture.onKey` → `KeyTracker`; yani Early aşamadan **sonra**. Early aşama `FINISH_HANDLED` dönerse KEY_DOWN bize hiç gelmez — kart bu noktada haklı.
2. Ama yutma koşullu: `checkForLeavingTouchModeAndConsume` gezinme tuşunda (oklar, Tab, Space, Enter, PageUp/Down, Home/End, DPAD_CENTER) `return ensureTouchMode(false)`; bu da `leaveTouchMode()` sonucunu döner:
   - odaklı görünüm ViewGroup **değilse** → `false` ("some view has focus, let it keep it") → **tüketilmez**;
   - odaklı ViewGroup `FOCUS_AFTER_DESCENDANTS` değilse → `false`;
   - yalnız odak yoksa (ya da odak `FOCUS_AFTER_DESCENDANTS` bir ViewGroup'taysa) `mView.restoreDefaultFocus()` çalışır; yeni odak yerleşirse `true` → KEY_DOWN tüketilir.
3. İstemcide akış sırasında odak hep `video`'da (SurfaceView, ViewGroup değil):
   - `video.isFocusable = isFocusableInTouchMode = true`; `syncPointerCapture` yakalama her (yeniden) istendiğinde önce `video.requestFocus()` çağırıyor (akış başı, panel kapanışı, odak dönüşü; 1 s ticker de `syncInputActive` çağırıyor).
   - `enterTouchMode()` yalnız `!isFocusableInTouchMode` odağı temizler; `video` dokunma kipine girerken odağını korur.
   - Ayar paneli açıkken giriş kapalı → yakalama bırakılır; kapanışta panel `GONE` (odaklı çocuk `clearFocus` → kök yeniden odaklar, ilk çocuk `video`) ve `syncInputActive` → `requestFocus` + yakalama. Bağlantı paneli (`panel`) `GONE` olunca aynı. `PenOverlayView` `isFocusable=false`; akışta başka odaklanabilir görünüm yok.
   - Cihaz kanıtı: NOTES 2026-10-05 ~15:00 dumpsys'te `app:id/video` odaklı (`.F....`).
   Dolayısıyla dokunuştan sonraki ilk Space/ok `leaveTouchMode` → `false` → **iletiliyor**. Bu tuş yalnız dokunma kipinden çıkarır (T-246'nın odak vurgusu sorunu budur), yutulmaz.
4. Kartın varsayımı düzeltmesi: tek başına UP gelse bile Mac'e gitmez. `KeyTracker` yalnız gönderilmiş DOWN'ların UP'ını gönderir (`held.remove(k) ?: return KeyDecision(true)`); yani en kötü durum tuş kaybıdır, eşleşmeyen UP ya da takılı tuş değil. Bu yüzden `key_orphan_up` sayacı eklenmedi (meşru nedenlerle de olur: release-all sonrası geç UP, panel açıkken basılıp kapanınca bırakılan tuş; gürültülü olurdu).

### Varsayımlar / test edilmeyenler

- HarmonyOS 4.3'ün `ViewRootImpl`'i AOSP 12 ile aynı varsayıldı; Huawei değişikliği yalnız cihazda görülür.
- Akıştan önce (bağlantı paneli, dokunma kipi, odak yok) gezinme tuşu yutulabilir; o anda tuşlar zaten Mac'e gitmiyor, etkisiz.

### Tablette kontrol (orkestratör)

1. Akış açık (Günlük ve Oyun), parmakla/kalemle ekrana dokun, sonra fiziksel klavyede **tek** Space bas: Mac'te tek boşluk (ör. TextEdit) ve host `ev=` tuş sayacında 1 DOWN + 1 UP.
2. Aynısını ok tuşu, Enter ve Tab ile tekrarla (her biri dokunuştan hemen sonra, ilk basış).
3. Ayar panelini (Ctrl+Shift+6) aç, klavye oklarıyla panelde gezin, kapat, dokun, ilk Space'i dene.
4. Kayıp görülürse: `adb shell dumpsys window windows` / `dumpsys activity top` ile odaklı görünüm (`video` `.F....` mı?) not edilsin; o zaman OnTouchModeChangeListener koruması (Plan 3) uygulanır.

### Open questions

- Yok.
