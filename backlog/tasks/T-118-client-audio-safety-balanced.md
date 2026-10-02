---
id: T-118
title: Tablet — ses güvenlik payı "dengeli" politika (hızlı küçülme, hatırlanan değer en çok 30 ms, alt taşma sonrası aşırı dolumu kısalt)
status: todo
phase: 5
owner: android-client-dev
depends_on: [T-117]
decisions: [0011, 0012]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/audio/
  - client-android/app/src/test/
  - backlog/tasks/T-118-client-audio-safety-balanced.md
---

## Amaç

NOTES 2026-10-02 ~10:10 (T-116/T-117 cihaz ölçümü, USB):
- Aktarım neredeyse temiz: 6,5 dakikada 1 alt taşma. O anda paket aktarımda ~40 ms tutuldu.
- Ama ses ~80 ms, görüntü ~36 ms; `av_offset_ms` ~44.
- Asıl maliyet hatırlanan güvenlik payı: `safety_ms` 35–40.
  - T-108 politikası: alt taşma başına +5 ms (tavan 40). Küçülme yalnız çalarken, 60 temiz pencerede −1 ms; 40 → 20 ≈ 20 dk sürekli ses. Değer saklanıyor.
  - Alt taşmadan sonra yeniden dolum hedefi `target + lastSpan`; seviye 75 ms'ye, `audio_ms` 113'e çıkıyor ve PI (en çok 5 ms/s) >10 s'de geri getiriyor.

**Kullanıcı kararı (2026-10-02):** "Dengeli". Pay temiz geçen sürede saniyeler ölçeğinde küçülsün, hatırlanan değer en çok ~30 ms olsun. Hedef ses ~60–65 ms. Nadir takılmada çok kısa, yumuşatılmış (T-108 fade) bir kesinti kabul.

## Kapsam dışı

- Aktarım tarafı (adb tüneli / Wi-Fi): ayrı araştırma.
- AAudio çıkış arabelleği boyu (T-114, 4 burst).
- Videoyu sese göre geciktirmek (yapılmayacak: girdi gecikmesi).
- AudioTrack ("Uyumlu") yolunun tabanı: aynı kurallar uygulanabilir, ayrı ayar gerekmez; Plan'da belirt.

## Kabul kriterleri

- [ ] **Hatırlanan değer tavanı:** `SafetyMemory` en çok 30 ms saklar ya da başlatır (`REMEMBER_MAX_MS = 30`). Eski 40'lık kayıt açılışta 30 olarak okunur. Oturum içi tavan 40 kalır.
- [ ] **Hızlı küçülme:** temiz pencerede (alt taşma yok) pay saniyeler ölçeğinde tabana iner. Hedef: 40 → 20 en çok ~2 dk temiz çalma (örneğin her 5 temiz pencerede −1 ms). Plan'da gerekçe ve seçilen sayı yazılır. Alt taşma adımı +5 ms kalır.
- [ ] **Alt taşma sonrası dolum:** yeniden dolum seviyesi `audio_ms`'i kalıcı şişirmez.
  - Alt taşmadan sonra en geç ~3 s içinde seviye yeni hedefin ±5 ms'ine döner.
  - Ya dolum hedefinden `lastSpan` payı kaldırılır ya da sınırlandırılır, ya da hedefin üstündeki fazla hızlı ama duyulmaz biçimde boşaltılır.
  - Perde (pitch) sapması ≤ %0,5 kalır; daha hızlı boşaltma gerekiyorsa sessiz anlarda kare atlama gibi duyulmaz bir yol Plan'da gerekçelendirilir.
- [ ] Log: ses `ev=stats` satırında mevcut `safety_ms` yeterli. Açılışta saklanan → kullanılan değer bir kez loglanır (`safety_start stored= used=`).
- [ ] Birim testleri:
  - (a) saklı 40 → açılış 30;
  - (b) temiz akışta 40 → 20 süresi kabul aralığında;
  - (c) tek alt taşma +5 ve sonra tekrar küçülme;
  - (d) alt taşma sonrası seviye ≤ 3 s'de hedefe döner;
  - (e) mevcut T-108/T-110/T-114 testleri geçer ya da gerekçeyle güncellenir.
- [ ] `./scripts/check.sh` geçiyor. Cihaz testi orkestratörde.

## Plan

_(Ajan kodlamadan önce doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
