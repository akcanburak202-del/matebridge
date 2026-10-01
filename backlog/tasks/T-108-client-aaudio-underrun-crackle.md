---
id: T-108
title: Tablet — Düşük gecikme (AAudio) seste oyun sırasında cızırtı; güvenli başlangıç tamponu, öğrenilen değeri hatırlama, boşalmada yumuşak geçiş
status: todo
phase: 5
owner: android-client-dev
depends_on: [T-101]
decisions: [0012]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/audio/
  - client-android/app/src/main/cpp/mbaudio.cpp
  - client-android/app/src/test/
  - backlog/tasks/T-108-client-aaudio-underrun-crackle.md
---

## Amaç

Kullanıcı bulgusu (2026-10-01/02, Witcher 2):
- "Düşük gecikme" ses çıkışında hafif cızırtı var, kalabalık uğultusu gibi sürekli seslerde duyuluyor.
- "Uyumlu" modda cızırtı yok.

Orkestratör log analizi (tablet `MB/audio ev=stats`, AAudio):
- `DriftController` güvenlik payı (safety) **5 ms** ile başlıyor ve her jitter-tampon boşalmasında (`underruns`) 5 ms büyüyor.
- Bir oturumda 5 dakikada 6 boşalma oldu (5→10→15→20→25→28→33 ms); `xruns=0`. Host tarafı temiz (`dropped=0`).
- Her boşalma bir tık. Sürekli seslerde cızırtı olarak duyuluyor.
- AudioTrack yolunda hedef ~21–22 ms ve boşalma yok.

## Kabul kriterleri

- [ ] AAudio yolunda safety başlangıcı güvenli bir değerdir: **20 ms**, sabit olarak adlandırılır. Kayıtlı öğrenilmiş değer varsa o kullanılır. AudioTrack yolu değişmez.
- [ ] **Öğrenilen safety hatırlanır.**
  - Oturum sonunda (ya da değiştikçe, seyrek) çıkış yoluna göre (aaudio/track) kalıcı saklanır. `audio/` paketinde kendi küçük deposu olur; `Settings.kt` ve `MainActivity` dokunulmaz, gerekiyorsa *Open questions*'a yazılır.
  - Sonraki bağlantı oradan başlar: `max(20 ms, kayıtlı)`.
  - Mevcut yavaş küçülme kuralı korunur.
  - Üst sınır mevcut 40 ms.
- [ ] **Boşalmada tık olmaz.**
  - Jitter tamponu boşalınca çıkış sert biçimde sıfıra düşmez: eldeki son örneklerle kısa bir sönüm (fade-out, mevcut `AudioRamp`) yapılır.
  - Yeniden başlarken fade-in olur.
  - Bugünkü davranış zaten böyleyse Plan'da kanıtıyla yazılır, tık kaynağı başka yerde aranır: AAudio callback'inde veri yokken ne yazılıyor?
- [ ] A/V senkronu bozulmaz (`av_offset_ms`, `audio_ms` mantığı aynı). Log alanlarına başlangıç safety'si ve kaynağı eklenir: `safety_init_ms=… source=default|stored`.
- [ ] Testler:
  - başlangıç değeri (varsayılan/kayıtlı);
  - kayıt ve geri okuma;
  - boşalmada çıkış örneklerinin sönümle sıfıra inmesi (ani sıçrama yok, en büyük örnek farkı sınırlı).
- [ ] `./scripts/check.sh` geçiyor. Cihaz testi orkestratörde (oyunda uğultulu sahne).

## Plan

(ajan doldurur, commit eder, sonra uygular)

## Handoff
