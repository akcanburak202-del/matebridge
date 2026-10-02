---
id: T-125
title: Tablet — alt taşmadan sonra geç gelen toplu ses paketleri seviyeyi şişirmesin (çalarken ileri atla, yumuşak geçişle)
status: todo
phase: 5
owner: android-client-dev
depends_on: [T-118, T-123]
decisions: [0011]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/audio/
  - client-android/app/src/test/
  - backlog/tasks/T-125-client-audio-late-bunch-skip.md
---

## Amaç

Cihaz (Wi-Fi, 2026-10-02 ~12:40, NOTES'a eklenecek):
- t=258'de tek bir ~80 ms gecikmeyle (`owd_max` 94) alt taşma olur.
- Çalma, birkaç paketle yeniden başlar (T-118 kırpması başlangıçta yapılır, `refill_trims` +1). Ama geciken paketler çalma **başladıktan sonra** toplu gelir.
- Seviye hedefin (45 ms) çok üstüne çıkar: `level_ms` 85 → ikinci alt taşmadan sonra (t=269) 134, `refill_trims` artmadı.
- `audio_ms` 187'ye, `av_offset_ms` 149'a çıkar. PI denetleyici (en çok 5000 ppm ≈ 5 ms/s) bunu ~20 s'de geri alır.
- Kullanıcı bunu kesintinin ardından sesin uzun süre görüntünün gerisinde kalması olarak yaşar.

Alt taşmada zaten bir boşluk duyuldu. Ardından gelen fazlayı çalmak yerine atlamak daha iyi.

## Kapsam dışı

- Güvenlik payı politikası (T-118/T-123 değerleri).
- Ağ tarafı (T-124).

## Kabul kriterleri

- [ ] Çalma sürerken seviye, alt taşmadan sonraki kısa pencerede (örneğin ilk 2 s; Plan'da gerekçe) `target + eşik` üstüne çıkarsa en eski fazlalık atılır. Örnek eşik: 20 ms.
  - Atlama tıklama yapmamalı: kısa çapraz geçiş ya da sön/yüksel (≤ 5 ms).
  - Bir alt taşma penceresinde en çok bir atlama.
  - Sayaç: `skip_trims=`, `skip_trim_ms=` (stats satırı).
- [ ] Alt taşma penceresi dışında, seviye çok yüksekse (örneğin > `target + 60 ms`, 3 s boyunca) yine tek seferlik atlama yapılır. Normal sapma PI ile düzeltilmeye devam eder. Bu, sessizlikten sonra başlayan seslerin başını kesmemelidir (T-118 `idleRestart` kuralına benzer biçimde).
- [ ] A/V hedefi (AvSync tabanı) atlamayla bozulmaz: hold sonrası bilinçli yüksek seviye atılmaz.
- [ ] Birim testleri:
  - (a) alt taşma + 80 ms sonra toplu varış → seviye ≤ 1 s'de hedef ±10 ms;
  - (b) sessizlik sonrası yeni ses başı kesilmez;
  - (c) A/V hold seviyesi korunur;
  - (d) T-118 `UnderrunRefillTest` geçer.
- [ ] `./scripts/check.sh` geçiyor. Cihaz testi orkestratörde.

## Plan

_(Ajan kodlamadan önce doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
