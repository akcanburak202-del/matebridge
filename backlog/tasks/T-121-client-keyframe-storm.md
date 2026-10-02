---
id: T-121
title: Tablet — kısa kare yığılmasında keyframe fırtınası (MAX_PENDING=2 → bırak-hepsini + KEYFRAME_REQUEST); yığılmayı yut, istekleri sınırla
status: todo
phase: 5
owner: android-client-dev
depends_on: [T-120]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionController.kt
  - client-android/app/src/test/
  - tools/pacing/
  - backlog/tasks/T-121-client-keyframe-storm.md
---

## Amaç

Cihaz (2026-10-02 ~11:00, NOTES'a eklenecek): ses kesintilerinin kökü bir **keyframe fırtınası**. İncelenen her büyük ses boşluğundan (60–253 ms) hemen önce host logunda 100–300 ms içinde art arda 4–6 `keyframe_request` var:
- çoğu `reason=2` FRAMES_DROPPED;
- arada `reason=0` STARTUP ve `codec_config_resent`.

Örnek (USB, 120 Hz, imleç hareketi):
- tablet `MB/decoder` bir saniyede `bytes` 476 KB → **4,87 MB**, `drop=24`;
- `MB/render` `late_drops=46`;
- aynı anda ses `owd` 13 → 41 ms, alt taşma.

T-120 `tick_late_ms=0.1`: tablet süreci donmamış. Veri gerçekten geç geldi, çünkü birkaç büyük IDR (2800×1840, her biri yüzlerce KB – ~1 MB) bağlantıyı (USB ya da Wi-Fi) dolduruyor ve ses arkada kalıyor.

`FrameQueue` (`MAX_PENDING = 2`):
- Bekleyen kare 2'yi aşınca tüm bekleyenleri ve geleni atıyor, keyframe gelene kadar kapıyı kapatıyor ve `KEYFRAME_REQUEST(FRAMES_DROPPED)` üretiyor.
- 120 fps'te çözme ~10–15 ms (boru hattında 3 kare). Ağdan 3–4 karelik kısa bir yığılma bu yüzden tam sıfırlamaya yetiyor.
- IDR'nin kendisi büyük ve yavaş çözülüyor; arkasından yine taşma oluyor ve bir istek daha geliyor. Zincirleme fırtına bu.

## Kapsam dışı

- Host tarafı istek birleştirme (T-122, paralel).
- Kodlayıcı ayarları (IDR boyutu, intra refresh): ayrı karar.
- Protokol değişikliği.

## Kabul kriterleri

- [ ] **Kök neden ölçümü:** taşma anında bir `W`/`I` satırı yazılır. İçeriği: bekleyen kare sayısı, codec'teki kare sayısı (`in_codec`), son çözme süresi, son varış aralıkları, taşmanın keyframe'den sonraki kaçıncı kare olduğu. `reason=0 STARTUP`'ın akış ortasında neden gönderildiği (codec yeniden başlatma mı?) bulunur, Plan/Handoff'a yazılır.
- [ ] **Kısa yığılmayı yut:** sınırlı bir derinliğe kadar (örneğin 120 fps'te ~6–8 kare ≈ 50–65 ms; Plan'da gerekçe) bekleyen kareler atılmaz. Çözücü yetişir, sunumda zaten "en yeni kazanır" kuralı geçerlidir (pacer eski kareyi göstermez).
  - Gerçek taşma (sınır aşıldı) bugünkü gibi bırak + istek.
  - AGENTS.md kuralı korunur: kuyruk sınırlıdır, eski kare gösterilmez.
  - Plan'da gecikme etkisi yazılır: yığılma sırasında geçici; sürekli çözücü yetersizliğinde sınırla kesilir.
- [ ] **İstek sınırı:** bir KEYFRAME_REQUEST'ten sonra keyframe gelene kadar ya da en az 500 ms (sabit, Plan'da gerekçeli) yeni FRAMES_DROPPED isteği gönderilmez. STARTUP / DECODE_ERROR hemen gider ama aynı kural uygulanır (aynı keyframe'i bekle).
- [ ] Sayaçlar: `MB/decoder` stats satırına `kf_req=`, `overflows=`, `max_pending=` eklenir.
- [ ] Birim testleri:
  - (a) 120 fps akışta 4 karelik yığılma → atma yok, istek yok;
  - (b) sürekli yetersiz çözücü → sınırda atma + tek istek;
  - (c) 500 ms içinde ikinci taşma → ikinci istek yok;
  - (d) keyframe gelince kapı açılır;
  - (e) mevcut `FrameQueue` testleri geçer ya da gerekçeyle güncellenir.
- [ ] `./scripts/check.sh` geçiyor. Cihaz testi orkestratörde.

## Plan

_(Ajan kodlamadan önce doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
