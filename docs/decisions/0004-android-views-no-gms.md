# 0004 — Android: Views + SurfaceView, Compose yok, GMS yok

- **Durum:** kabul
- **Tarih:** 2026-09-29

## Bağlam
İstemcinin arayüzü çok küçük: bağlantı ekranı, tam ekran video, istatistik katmanı. Asıl iş `SurfaceView`, MediaCodec ve girdi olaylarında. Cihazda (HarmonyOS 4.3) Google Play Services yok.

## Karar
Android Views + `SurfaceView`, Kotlin, coroutines. Jetpack Compose, DI çerçeveleri, Firebase/GMS kullanılmaz. Keşif için Android `NsdManager` (mDNS) kullanılır.

## Sonuçlar
- Az bağımlılık, küçük APK, girdi olaylarına doğrudan erişim.
- Yeni kütüphane eklemek için yeni bir karar kaydı gerekir.
