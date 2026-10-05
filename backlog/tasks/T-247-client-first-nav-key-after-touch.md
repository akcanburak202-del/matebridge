---
id: T-247
title: Client — verify (and fix) that the first navigation key after a touch is not swallowed by ViewRootImpl leaving touch mode
status: in-progress
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

- [ ] Handoff'ta kaynak analizi: sorun bu istemcide var mı.
- [ ] Varsa: [JVM] yakalama yolunun tek seferlik ve eşleşmeli olduğu testleri; `./scripts/check.sh` geçer.
- [ ] [device, orkestratör] dokunuştan sonra ilk Space/ok tuşunun Mac'te göründüğü (host `ev=` tuş sayacı).

## Plan

1. Kaynak analizi (kod yok): AOSP `android12-release` `ViewRootImpl` (`EarlyPostImeInputStage.processKeyEvent` → `checkForLeavingTouchModeAndConsume` → `ensureTouchMode(false)` → `leaveTouchMode`) ile istemcinin tuş yolunu (`MainActivity.dispatchKeyEvent` → `routeKeyEvent` → `InputCapture.onKey` → `KeyTracker`) ve odak kurulumunu (`video` SurfaceView, `syncPointerCapture`) karşılaştır.
2. Yutma yalnızca dokunma kipinde, odak yokken (ya da odak `FOCUS_AFTER_DESCENDANTS` bir ViewGroup'tayken) ve `restoreDefaultFocus()` yeni odak yerleştirdiğinde olur. Akış sırasında bu koşulun oluşup oluşmadığını tüm odak yollarında kontrol et.
3. Sorun varsa: `video` odağını garanti eden yalıtılmış bir koruma (ör. `ViewTreeObserver.OnTouchModeChangeListener`, `leaveTouchMode`'dan önce çağrılır) + JVM testli saf karar sınıfı. Sorun yoksa: kod değişikliği yok; sonuç ve cihaz kontrolü Handoff'a.

## Handoff

_(Ajan bitirince doldurur.)_
