---
id: T-358
title: İstemci — tablet kamerasında "Arka geniş açı" seçeneği
status: todo
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

## Handoff

## Open questions
