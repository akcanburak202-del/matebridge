---
id: T-116
title: Host — ses gönderim zamanlaması ölçümü (oturum kuyruğu bekleme, yakalama→yazım, yazımlar arası en büyük aralık)
status: todo
phase: 5
owner: mac-host-dev
depends_on: []
decisions: [0011]
files:
  - host-mac/Sources/MateBridgeHost/Session/SessionServer.swift
  - host-mac/Sources/MateBridgeHost/Audio/
  - host-mac/Sources/MateBridgeCore/Audio/
  - host-mac/Tests/MateBridgeCoreTests/
  - docs/LOGGING.md
  - backlog/tasks/T-116-host-audio-send-timing.md
---

## Amaç

NOTES 2026-10-02 ~09:20: tabletin ses jitter tamponu oturum başına ~11 kez 25–40 ms boş kalıyor. Bu yüzden güvenlik payı 30–40 ms'ye büyüyor ve ses görüntüden geride kalıyor.

Host'un yakalama tarafı düzenli: `ring_ms_max=10`, 100 paket/s. Ama `sendAudio` → `drainAudio` → ortak `dev.matebridge.session` kuyruğu → mühürleme → `write()` yolu ölçülmüyor. Aynı kuyruk gelen girdiyi de işliyor (`InputController.deliver` içinde `queue.sync` + CGEvent).

Bu kart yalnız ölçüm ekler; düzeltme yok. T-117 (tablet varış ölçümü) ile birlikte gecikmenin host'ta mı, aktarımda mı, tablette mi oluştuğunu ayırır.

## Kapsam dışı

- Ses yolunu ayrı kuyruğa/iş parçacığına taşımak ya da başka bir davranış değişikliği (ölçüm sonucuna göre ayrı kart).
- Protokol değişikliği.
- Tablet tarafı (T-117).

## Kabul kriterleri

- [ ] `ev=stats` ses satırına (ya da ayrı, saniyelik bir `ev=send` ses satırına; `docs/LOGGING.md`'ye yazılır) şu alanlar eklenir:
  - `queue_lag_ms_p50/max`: `sendAudio` çağrısından oturum kuyruğunda drain'e kadar;
  - `cap_to_write_ms_p50/max`: paketin `capture_time_us` değerinden `write()` dönüşüne kadar;
  - `write_int_ms_max`: ardışık ses yazımları arası en büyük aralık;
  - `write_block_ms_max` ya da kısmi yazım/bekleyen bayt sayısı (soket yazımı EAGAIN/partial'a düştü mü).
- [ ] Bir ses yazımı önceki yazımdan > 20 ms sonra gerçekleşirse tek bir `debug` satırı yazılır: aralık, kuyruk beklemesi, o anda kuyrukta en son işlenen girdi/kontrol mesajı türü (içerik değil), bekleyen bayt. Hız sınırlı (saniyede en çok 5).
- [ ] Gizlilik: tuş/metin içeriği loglanmaz; yalnız mesaj türü.
- [ ] Ölçüm maliyeti: paket başına sabit, kilitsiz ya da kuyruk içinde; ses ve girdi yolunu yavaşlatmaz.
- [ ] Hesaplama (yüzdelik, aralık) Core'da ve birim testli.
- [ ] `./scripts/check.sh` geçiyor. Cihaz ölçümü orkestratörde.

## Plan

_(Ajan kodlamadan önce doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
