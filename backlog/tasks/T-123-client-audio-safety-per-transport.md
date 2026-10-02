---
id: T-123
title: Tablet — ses güvenlik payı bağlantı türüne göre (USB / Wi-Fi ayrı hatırlansın, Wi-Fi tabanı yüksek); geçişte pay hemen uyarlansın
status: todo
phase: 5
owner: android-client-dev
depends_on: [T-118]
decisions: [0011, 0012]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/audio/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionController.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/
  - backlog/tasks/T-123-client-audio-safety-per-transport.md
---

## Amaç

NOTES 2026-10-02 ~11:35: keyframe fırtınası bittikten sonra USB'de ses temiz. 14 dakikada en büyük varış boşluğu 33 ms, 1 alt taşma.

Wi-Fi'de ise saf ağ titreşimi var:
- varış boşlukları 41–50 ms, `owd` 39–65 ms;
- RTT p50 15–37, p95 en çok 126 ms.

`SafetyMemory` tek değer saklıyor (API başına: `aaudio` / `track`). USB'de öğrenilen 20–30 ms Wi-Fi'ye geçince yetmiyor ve kullanıcı 1–2 dakikada 5 kesinti duydu. Tersi de sorun: Wi-Fi'de büyüyen pay USB'ye dönünce gecikme olarak kalıyor (T-118 küçülmesi 100 s sürüyor).

Kullanıcı kararı "Dengeli" (T-118) geçerli. Bu kart onu bağlantı türüne göre ayırır.

## Kapsam dışı

- Wi-Fi titreşiminin kendisi (ağ ayarları, QoS): ayrı konu.
- Görüntü tarafı.

## Kabul kriterleri

- [ ] `SafetyMemory` anahtarı `api + transport` olur (`aaudio/usb`, `aaudio/wifi`, `track/usb`, `track/wifi`). Eski tek anahtarlı kayıt USB değeri olarak taşınır (göç), Wi-Fi varsayılandan başlar.
- [ ] Wi-Fi başlangıç tabanı ve hatırlama tavanı USB'den yüksektir. Öneri: AAudio Wi-Fi başlangıç 40 ms, hatırlama tavanı 50, oturum içi tavan 60–70 ms. Plan'da ölçüme dayalı gerekçe: Wi-Fi `owd` p95/max ve RTT dağılımı. Küçülme hızı T-118 ile aynı. Wi-Fi'de pay öğrenilen değerin altına inmez mi, inerse ne kadar, Plan'da yazılır.
- [ ] Oturum ortasında bağlantı değişince (Otomatik mod USB ↔ Wi-Fi, `transport_migrate` / yeni oturum) ses çıkışı yeniden açılmadan pay o bağlantının hatırlanan değerine geçer. Artış hemen olur (kısa bir dolum gerekiyorsa yumuşak); azalış normal küçülme yoluyla olur.
- [ ] Log: `ev=safety_start ... transport=usb|wifi`. Geçişte `ev=safety_transport from= to= used=`.
- [ ] Birim testleri:
  - (a) göç: eski 30 → usb 30, wifi varsayılan;
  - (b) Wi-Fi'de büyüyen pay USB kaydını etkilemez;
  - (c) geçişte pay doğru değere gider;
  - (d) T-118 testleri geçer.
- [ ] `./scripts/check.sh` geçiyor. Cihaz testi orkestratörde.

## Plan

_(Ajan kodlamadan önce doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
