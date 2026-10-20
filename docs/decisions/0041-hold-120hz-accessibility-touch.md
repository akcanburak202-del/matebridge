# 0041 — Kumandayla 120 Hz: erişilebilirlik servisiyle basılı sahte dokunma (deneysel, varsayılan kapalı)

- **Durum:** reddedildi (2026-10-21) — cihazda çalışmadı, kod geri alındı
- **Tarih:** 2026-10-20

## Bağlam

Huawei AGP paneli yalnız dokunma, kalem, fare ya da trackpad görünce 120 Hz'e çıkarıyor; klavye ve kumandayla oyunda panel 60'ta kalıyor ve host `DISPLAY_RATE` yüzünden akışı 60'a indiriyor (0016, T-140, T-243). 2026-10-05'te sahte dokunma yolu "gerek yok" denerek bırakılmıştı; kullanıcı 2026-10-20'de yeniden istedi.

NOTES 2026-10-20 ~22:00: `adb shell input touchscreen motionevent DOWN` ile basılı tutulan tek bir dokunma paneli 40 sn kesintisiz 120'de tuttu; kısa dokunma 1,5–2,5 sn. Fare olayı shell'den gönderilemiyor (`INJECT_EVENTS`). Sahte dokunma istemciye ve oradan Mac'e işaretçi olarak ulaştı.

## Karar

- İstemciye bir **erişilebilirlik servisi** eklenir (`canPerformGestures`). Servis `dispatchGesture` ile **basılı, hareketsiz tek bir dokunma** tutar; uzun süre için `StrokeDescription.continueStroke` zinciri kullanılır. adb gerekmez.
- Dokunma **Mac'e asla gitmez.** Hedef, servisin kendi küçük `TYPE_ACCESSIBILITY_OVERLAY` penceresidir (izin gerektirmez, dokunmayı yutar, gerçek dokunmalarla çoklu dokunmaya karışmaz). Bu pencere AGP'yi tetiklemezse yedek yol: dokunma video yüzeyine düşer ve istemci onu kaynağından tanıyıp atar.
- Panelde **"Kumandayla 120 Hz"** anahtarı. **Varsayılan kapalı.** Servis izni yoksa anahtarın altında "Erişilebilirlik izni gerekli" ve Ayarlar'ı açan bir düğme.
- Yalnız şu koşullarda çalışır: anahtar açık, servis bağlı, video akıyor, uygulama ön planda, oturum uzak değil, **Oyun modu ve 120 fps**. Biri bozulunca dokunma hemen bırakılır.
- Gerçek dokunma basılı hareketi iptal ederse (Android böyle yapar) gerçek dokunma bitince kısa bir gecikmeyle yeniden başlatılır.

## Sonuçlar

- Kumandayla Oyun 120 gerçekten 120 fps olabilir. Bedeli: panel ve çözme sürekli 120'de, pil ve ısı artar (ölçülecek).
- Erişilebilirlik izni kullanıcıdan bir kez istenir. Servis yalnız jest gönderir; ekran içeriği okumaz (`canRetrieveWindowContent=false`, olay türü yok).
- Huawei'ye özgü davranışa dayanır; HarmonyOS güncellemesinde etkisiz kalabilir.
- Yeniden düşünme: AGP servis jestini saymazsa ya da pil bedeli kabul edilemezse anahtar kaldırılır.

## Ek (2026-10-21): reddedildi

Cihaz testi (NOTES 2026-10-21 ~01:00): erişilebilirlik `dispatchGesture` olayları Huawei InputDispatcher'da hiçbir pencereye eşlenmiyor (`toolType 0`), panel 60'ta kalıyor. adb shell enjeksiyonu aynı overlay'de 120 veriyor, ama host'tan adb ile basılı dokunma (kablosuz adb yeniden başlatmada kaybolur) kullanıcı tarafından istenmedi. Kumandayla oyunda Oyun 60 doğru mod olarak kalır (0016). T-360 kodu main'den geri alındı.
