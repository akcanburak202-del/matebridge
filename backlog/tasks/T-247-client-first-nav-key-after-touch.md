---
id: T-247
title: Client — verify (and fix) that the first navigation key after a touch is not swallowed by ViewRootImpl leaving touch mode
status: todo
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

_(Ajan kodlamadan önce doldurur.)_

## Handoff

_(Ajan bitirince doldurur.)_
