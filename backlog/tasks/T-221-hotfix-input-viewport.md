---
id: T-221
title: Hotfix — input viewport stays empty after T-215's MATCH_PARENT layout
status: done
phase: 6
owner: orchestrator
depends_on: [T-215]
decisions: [0029]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - backlog/tasks/T-221-hotfix-input-viewport.md
---

## Amaç

Cihaz 2026-10-04 ~10:50 (sürüm `cea1809`): kurulumdan sonra klavye, kalem ve trackpad hiç çalışmadı; video `healthy` olduğu halde `input_active on=1` hiç gelmedi. Neden: input penceresi (`viewport`) yalnız video görünümünün yerleşimi değişince (`addOnLayoutChangeListener`) hesaplanıyordu. T-215 görünümü yerel ekranda da `MATCH_PARENT` yaptı; akış ayarı gelince `layoutVideo` aynı parametreleri bulup yerleşim değiştirmedi → dinleyici çalışmadı → `viewport` ilk (config yokken) hesaplanan boş hâlde kaldı → `syncInputActive` hep kapalı.

## Düzeltme

`updateViewport()`: yerleşim dinleyicisi ve `layoutVideo`'nun "parametre değişmedi" dalı onu çağırır; viewport'u görünümün geçerli dikdörtgeninden yeniden hesaplar, kalem katmanına verir ve `syncInputActive()` çağırır.

Acil düzeltme olduğu için orkestratör yaptı (kullanıcı tabletle Mac'i kontrol edemiyordu). Takip: config değişince viewport'un yeniden hesaplandığını sınayan JVM testi için `layoutVideo`/viewport mantığını saf bir sınıfa çıkarmak (T-222 önerisi).

## Kabul kriterleri

- [x] [device] Kurulumdan sonra `video_health healthy` → `input_active on=1` (10:54:44); kullanıcı doğrulaması aşağıda.
- [x] [device] Kullanıcı: klavye, kalem, trackpad çalışıyor (Oyun 60, 1848×1214), 2026-10-04 ~10:56.

## Handoff

- **Dokunulan dosyalar:** MainActivity.kt (viewport hesabı `updateViewport()`'a taşındı).
- **Test edilmeyenler:** JVM testi yok (Activity); cihazda doğrulandı.
