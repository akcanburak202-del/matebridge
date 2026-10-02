---
id: T-116
title: Host — ses gönderim zamanlaması ölçümü (oturum kuyruğu bekleme, yakalama→yazım, yazımlar arası en büyük aralık)
status: done
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

- [x] `ev=stats` ses satırına (ya da ayrı, saniyelik bir `ev=send` ses satırına; `docs/LOGGING.md`'ye yazılır) şu alanlar eklenir:
  - `queue_lag_ms_p50/max`: `sendAudio` çağrısından oturum kuyruğunda drain'e kadar;
  - `cap_to_write_ms_p50/max`: paketin `capture_time_us` değerinden `write()` dönüşüne kadar;
  - `write_int_ms_max`: ardışık ses yazımları arası en büyük aralık;
  - `write_block_ms_max` ya da kısmi yazım/bekleyen bayt sayısı (soket yazımı EAGAIN/partial'a düştü mü).
- [x] Bir ses yazımı önceki yazımdan > 20 ms sonra gerçekleşirse tek bir `debug` satırı yazılır: aralık, kuyruk beklemesi, o anda kuyrukta en son işlenen girdi/kontrol mesajı türü (içerik değil), bekleyen bayt. Hız sınırlı (saniyede en çok 5).
- [x] Gizlilik: tuş/metin içeriği loglanmaz; yalnız mesaj türü.
- [x] Ölçüm maliyeti: paket başına sabit, kilitsiz ya da kuyruk içinde; ses ve girdi yolunu yavaşlatmaz.
- [x] Hesaplama (yüzdelik, aralık) Core'da ve birim testli.
- [x] `./scripts/check.sh` geçiyor. Cihaz ölçümü orkestratörde.

## Plan

1. **Core `AudioSendTiming`** (`MateBridgeCore/Audio/AudioSendTiming.swift`, birim testli): oturum kuyruğunda yaşayan, kilitsiz değer tipi.
   - `noteReceived(type:startUs:endUs:)`: kontrol bağlantısında işlenen son mesajın türü ve bitişi, son ses yazımından bu yana en uzun işlenen mesaj (tür + süre).
   - `recordWrite(...)`: kuyruk beklemesi, yakalama→yazım, `write` çağrı süresi, yazım sonrası bekleyen bayt, yazım bitiş zamanı. Ardışık yazım aralığı > 20 ms ise `Gap` döner; saniyede en çok 5 (`gaps` sayacı hepsini sayar).
   - Saniyelik pencere: `writes`, `queue_lag_ms_p50_max`, `cap_to_write_ms_p50_max`, `write_int_ms_max`, `write_block_ms_max`, `partial_writes`, `pending_bytes_max`, `gaps` (en yakın sıra yüzdelik). `takeReportIfDue` / `flush` / `reset` (akış sınırında aralık sayılmaz).
2. **`AudioOutbox.Item.pushedUs`**: `push(..., nowUs:)` (varsayılan 0, mevcut testler değişmez); `sendAudio` damgalar.
3. **`SessionServer`**: `drainAudio` başında `now` ile kuyruk beklemesi; her ses `AUDIO_FRAME` yazımının (`sendControl`) süresi ve sonrası bekleyen bayt (`bsd`: `pendingBytes`; `nw`: yazımdan önceki `inflightBytes`). `receiveControlBytes` her mesajın türünü ve işleme süresini not eder. Saniyelik `component=audio ev=send` (info) satırı ve hız sınırlı `ev=send_gap` (debug) satırı; `AUDIO_CONFIG` geçince pencere boşaltılır ve sıfırlanır. Davranış değişmez.
4. **`docs/LOGGING.md`**: `ev=send` ve `ev=send_gap` alanları.
5. `./scripts/check.sh`, Handoff.

## Handoff

- **Commit:** `64764d6` (uygulama), `2e9bd0a` (plan). Dal `task/T-116-host-audio-send-timing`.
- **Dokunulan dosyalar:**
  - `host-mac/Sources/MateBridgeCore/Audio/AudioSendTiming.swift` (yeni): pencere, yüzdelik, aralık, boşluk ve hız sınırı.
  - `host-mac/Sources/MateBridgeCore/Audio/AudioOutbox.swift`: `Item.pushedUs`, `push(..., nowUs:)` (varsayılan 0).
  - `host-mac/Sources/MateBridgeHost/Session/SessionServer.swift`: `sendAudio` damgası, `drainAudio` ölçümü (`recordAudioWrite`, `closeAudioTimingWindow`), `receiveControlBytes` içinde mesaj türü ve işleme süresi.
  - `host-mac/Tests/MateBridgeCoreTests/Audio/AudioSendTimingTests.swift` (yeni, 11 test).
  - `docs/LOGGING.md`: `ev=send` ve `ev=send_gap`.
- **Varsayımlar:**
  - Ayrı satır seçildi: `component=audio ev=send` (info, ~1 sn, oturum kuyruğunda yazılır). Böylece `ev=stats`'a kuyruklar arası kilit gerekmez. Pencere ses yazımı olduğunda kapanır; ses durunca `AUDIO_CONFIG` kalan pencereyi yazar.
  - "Yazım" = mühürleme + `sendControl` çağrısının dönüşü. `bsd` kontrol soketinde `write` çekirdeğe eşzamanlı yazar (`Darwin.write`). Dönüşten sonra `pendingBytes > 0` ise EAGAIN ya da kısmi yazım olmuştur (`partial_writes`, `pending_bytes_max`). `nw`'de çekirdek görülemez; yazımdan önceki `inflightBytes` yazılır.
  - `write_block_ms_max` = tek mühürleme + yazım çağrısının süresi (soket kilidi beklemesi dahil).
  - `ev=send_gap` debug seviyesinde: yalnız `os.Logger`'a gider, `host.log`'a yazılmaz (SessionLogger kuralı). Görmek için `log stream --level debug --predicate 'subsystem == "dev.matebridge.host" AND category == "audio"'`.
  - Kart "en son işlenen girdi/kontrol mesajı türü" istiyor. Ek olarak, önceki ses yazımından bu yana en uzun işlenen mesajın türü ve süresi de var (`slow_rx`, `slow_rx_ms`; `apply(machine.received…)` süresi, CGEvent dahil). Yalnız `MessageType` adı yazılır, içerik yazılmaz.
  - Kuyruktaki başka işler (video bağlantısı okumaları, tick zamanlayıcısı, Keychain dönüşleri) `last_rx`'te görünmez. Yalnız kontrol bağlantısından gelen mesajlar izlenir.
  - Maliyet: paket başına 3 `nowUs()`, 2 dizi eklemesi, birkaç max. Gelen mesaj başına 1 ek `nowUs()`. Sıralama saniyede bir, ~100 değer. Kilit eklenmedi; tümü oturum kuyruğunda.
- **Test edilmeyenler / cihazda doğrulanacaklar:**
  - Gerçek oturumda `ev=send` satırının saniyede bir geldiği ve değerlerin makul olduğu (10 ms akışta `write_int_ms_max` ≈ 10–12).
  - Tabletteki boş kalma anlarında (NOTES 09:20) `ev=send_gap` görünüyor mu? `slow_rx` / `queue_lag_ms` girdi işlemeyi mi gösteriyor? Bu, T-117 varış ölçümüyle birlikte yorumlanmalı.
  - Kalem/klavye yoğun kullanımda ölçümün ses ve girdi gecikmesini değiştirmediği.
- **Açık sorular:** yok.
