---
id: T-390
title: İstemci — host'un 120 Hz tutma dokunmasını (adb tap 2,2) yut
status: todo
phase: 7
owner: android-client-dev
depends_on: [T-234]
decisions: [0044]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/input/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/
  - docs/LOGGING.md
  - backlog/tasks/T-390-client-swallow-hold120-tap.md
---

## Amaç

Karar 0044, istemci tarafı. Host USB'de saniyede bir `adb shell input touchscreen tap 2 2` gönderecek (T-389). Bu dokunma Huawei'nin paneli 120 Hz'te tutması için var; Mac'e **asla** gitmemeli ve boşta/kullanıcı etkinliği sayılmamalı.

## Kabul

1. **Ölçüt** (saf, birim testli sınıf, ör. `input/InjectedHoldTap.kt`): bir dokunma hareketi yutulur, ancak:
   - `ACTION_DOWN` olayının aygıtı gerçek bir giriş aygıtı değil: `InputDevice.getDevice(deviceId)` null ya da `isVirtual`;
   - kaynağı dokunmatik ekran;
   - tek parmak;
   - konumu sol üst köşede (`x ≤ 4 && y ≤ 4`, pencere = tam ekran).

   Ölçüt DOWN'da verilir; aynı `deviceId`'nin UP/CANCEL'ına kadar o hareketin bütün olayları yutulur. Gerçek aygıtlardan (dokunmatik ekran, kalem, touchpad, fare) gelen hiçbir olay bu ölçüte takılmaz; konum ne olursa olsun.
2. **Yer:** ölçüt `MainActivity.dispatchTouchEvent` içinde, yönlendirmeden (`routeToCapture`, `super`) **önce** uygulanır. Yutulan olay ne Mac'e gider ne de uygulamanın kendi görünümlerine (panel, düğmeler). `noteIdleInput()` / boşta sayacı (T-234) ve "kullanıcı etkin" sinyalleri bu olaydan beslenmez. `noteInputActivity()` (vsync uyandırma) çağrılabilir; zararsız.
3. Başka konumdaki adb dokunmaları (test araçları, ör. `input tap 1400 900` ya da `input stylus motionevent`) bugünkü gibi işlenir.
4. Yutma hiçbir gerçek girdi durumunu değiştirmez. Basılı tuş, kalem ya da işaretçi durumu etkilenmez; yarım kalan yutulmuş bir hareket (UP gelmeden CANCEL ya da arka plana geçiş) iz bırakmaz.
5. **Log:** `MB/input ev=hold_tap_swallowed n=<toplam>`, en çok 30 sn'de bir ve yalnız sayı değiştiyse (`debug` değil `info`; konum/aygıt adı yok). `docs/LOGGING.md` güncel.
6. Birim testleri: ölçüt (sanal/bilinmeyen aygıt + köşe → yut; gerçek aygıt + köşe → geçir; sanal + başka konum → geçir; çok parmak → geçir; DOWN..UP boyunca yutma; CANCEL ile temizlik).
7. `./scripts/check.sh` geçer. Cihaza kurulum ve deneme bu kartta YOK; orkestratör yapar.

## Plan

1. `input/InjectedHoldTap.kt`: saf sınıf. `onTouch(action, deviceId, source, pointerCount, rawX, rawY, isRealDevice: () -> Boolean): Boolean` true dönerse olay yutulur. DOWN'da ölçüt (ucuz kontroller önce: dokunmatik ekran kaynağı, tek parmak, `x<=4 && y<=4`; en son `isRealDevice()` arama); eşleşirse `deviceId` yutulanlar kümesine girer. Aynı `deviceId`'nin sonraki olayları UP/CANCEL dahil yutulur; UP/CANCEL kümeden çıkarır. Eşleşmeyen DOWN o `deviceId`'nin eski girdisini siler. `reset()`: arka plan/odak kaybında küme temizlenir. `takeLog(nowMs)`: sayı değiştiyse ve son logdan >= 30 sn geçtiyse toplamı döndürür.
2. `MainActivity.dispatchTouchEvent`: `noteInputActivity()` sonrası, `routeToCapture`'dan önce `InjectedHoldTap` sorgulanır; yutulursa `true` döner, `noteIdleInput()` çağrılmaz. `isRealDevice = { InputDevice.getDevice(id)?.isVirtual == false }`. `onPause` ve `onWindowFocusChanged(false)` içinde `reset()`.
3. Log `MB/input ev=hold_tap_swallowed n=<toplam>` (info); `docs/LOGGING.md` bölümü.
4. Birim testleri (JVM): kabul 6'daki bütün durumlar.

## Handoff

## Open questions

- Cihazda doğrulandı (orkestratör, 2026-11-08, saydam probe etkinliği): `input touchscreen tap 2 2` → `deviceId=-1` ("Virtual", `isVirtual=true`), `source=0x1002`, `toolType=1` (parmak), `x=2.0 y=2.0`, DOWN `pressure=1.0`, UP `pressure=0.0`, `flags=0`. Gerçek aygıtlar: dokunmatik ekran 6 (`input_mt_wrapper`), kalem 7 (`huawei,ts_pen`), Glide Keyboard touchpad 8; hepsi `isVirtual=false`.
