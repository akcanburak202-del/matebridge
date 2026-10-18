---
id: T-358
title: İstemci — tablet kamerasında "Arka geniş açı" seçeneği
status: review
phase: 7
owner: android-client-dev
depends_on: [T-355]
decisions: [0040]
files:
  - client-android/app/src/main/
  - client-android/app/src/test/
  - backlog/tasks/T-358-client-camera-wide.md
---

## Amaç

Kullanıcı (2026-10-18): arka geniş açı kamerası bir özellik olarak bulunsun. PROTOCOL.md 0x0E `facing = 2` BACK_WIDE (bilgi amaçlı; host bir şey yapmaz).

## Cihaz bilgisi (orkestratör, `dumpsys media.camera`, MatePad Pro 12.2)

- Kamera 0: arka, mantıksal çoklu kamera (`LOGICAL_MULTI_CAMERA`), fiziksel kimlikler `"2"` ve `"4"`; odak 6,98 mm, 4096×3072, `zoomRatioRange` 1,0–10,0 (1'in altı yok).
- Kamera 4: odak 1,95 mm, sensör 3,45×2,59 mm, 3264×2448: **geniş açı** (~83° yatay; ana kamera ~45°). `zoomRatioRange` 1,0–1,0.
- Kamera 1/3: ön, 2,7 mm, 3840×2160. "Number of normal camera devices: 3".
- Sensör yönü: arka 90, ön 270. T-355 döndürme kuralı (commit 25f80cd4: SurfaceTexture matrisi sensör yönünü içerir; yalnız ekran dönüşü + önde yatay çevirme) geniş açıda da geçerli olmalı. Cihazda doğrulanacak.

## Kapsam

1. `CameraFacing`'e `BACK_WIDE` (tel değeri 2) ekle; `camera_facing` ayarında saklanabilir.
2. Açma yolu (sırayla dene, ilk çalışanı kullan, sonucu logla):
   a) `getCameraIdList()` içinde arka yönlü ve en kısa odaklı ayrı bir kamera varsa onu doğrudan aç.
   b) Yoksa mantıksal arka kamerayı (`LOGICAL_MULTI_CAMERA`) aç ve `OutputConfiguration.setPhysicalCameraId(<en kısa odaklı fiziksel kimlik>)` ile oturum kur (fiziksel kimliğin özelliklerinden boyut ve fps seç).
   c) İkisi de olmazsa geniş açı **desteklenmiyor**: panel seçeneği gizli.
   Destek, uygulama başlarken ya da kamera ilk kez seçilirken bir kez belirlenir (kamera açmadan, yalnız `CameraCharacteristics` ile); sonuç önbelleğe alınır.
3. Panel: "Kamera yönü: Ön / Arka / Geniş açı" (destek yoksa iki seçenek). Akış sürerken değişim T-355'teki gibi aynı bağlantıda yeni CODEC_CONFIG + keyframe.
4. Seçili geniş açı kamerası açılamazsa (oturum hatası) `state=error reason=wide_unavailable` logla, BACK'e düş ve devam et; ayarı değiştirme.
5. Testler: seçim mantığı (en kısa odaklı arka fiziksel kimlik, liste/mantıksal yollar, destek yok), ayar saklama, panel seçenekleri. Camera2 çağrıları arabirim arkasında.

## Kabul

- `./scripts/check.sh --only android` geçer. Cihaz testi orkestratörde (görüş açısı, döndürme, aynalama yok).

## Plan

Saf secici `CameraTargets` (CamInfo listesi -> CameraTarget: openId/physicalId/charId); Camera2 tarafi `AndroidCameraTargets` yalniz CameraCharacteristics okur (kamera acmaz), destek bir kez belirlenip onbellege alinir. `CameraFacing.BACK_WIDE` (tel 2). Pipeline hedefi cozer, yol (b) icin `OutputConfiguration.setPhysicalCameraId`. Geniş açı hata verirse (cozulemedi/disconnect/error/session) `reason=wide_unavailable` loglanir, BACK'e dusulur, ayar degismez.

## Handoff

- Commit: branch task/T-358-client-camera-wide son commit (taban 19d83165).
- Dosyalar: camera/CameraTargets.kt (saf), camera/AndroidCameraTargets.kt, Camera2Pipeline.kt, CameraWish.kt (BACK_WIDE), protocol Messages/Codec (FACING_BACK_WIDE = 2, bilinmeyen = FRONT), SettingsCatalog (cameraWideAvailable; yoksa secenek gizli), MainActivity (kayitli Geniş açı destek yoksa BACK sayilir, ayar degismez), testler (CameraTargetsTest, SettingsCatalogTest).
- Beklenen acilma yolu bu cihazda: **(b)**. Kamera 4 id listesinde degil (normal kameralar 0, 1/3); 0 mantiksal, fiziksel "2" (6,98 mm) ve "4" (1,95 mm) -> mantiksal 0 acilir, `setPhysicalCameraId("4")`, boyut/fps/sensor yonu "4"un ozelliklerinden. Yol (a) yalniz listede ayri kisa odakli arka kamera varsa.
- Dondurme: T-355 25f80cd4 kurali degismedi. Fiziksel akista SurfaceTexture matrisinin ayni davrandigi cihazda dogrulanmali.
- Cihazda bak: logcat `camera_wide_probe wide=supported path=b_physical open=0 char=4`; panelde Ön / Arka / Geniş açı; Geniş açı'da Photo Booth'ta belirgin genis gorus (~83 derece), dik, aynasiz, ekran donunce dik; akis surerken Arka<->Geniş açı gecisi ayni baglantida yeni config+keyframe; fiziksel oturum hatasi olursa `reason=wide_unavailable` ve BACK'e dusus.
- Test edilmedi: Camera2 cagrilari (cihaz gerekli).

- Round 2 (task/T-358-client-r2): session-creation, repeating-request and open `CameraAccessException` paths (Camera2Pipeline 4 places) now go through `failOrFallback`, so a failing physical wide camera falls back to BACK instead of closing the stream; other facings unchanged. Decision is `CameraTargets.fallbackOnFailure` (unit-tested). Camera2 flow needs the tablet.

- Round 3 (task/T-358-client-r3): (1) the encoder drain thread no longer stops at `stopRequested`: it discards output until teardown has released GL/EGL (`renderDone`), with a 5 s upper bound, so a handler blocked in eglSwapBuffers on a full encoder can always finish teardown; codec stop/release happens after the drain is joined. (2) `failOrFallback` invalidates the open generation synchronously before posting the fallback, so a queued onError of the failed open is stale. Camera2 flows are not JVM-testable; tablet: start/stop and background the camera repeatedly (no leaked camera/handler after STOP), force a wide failure and confirm the fallback to BACK survives.

## Open questions
