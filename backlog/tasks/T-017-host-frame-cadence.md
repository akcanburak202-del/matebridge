---
id: T-017
title: Mac kare temposu — yakalama aralığı ölçümü, sanal ekran yenileme hızı, kayıp karelerin kaynağı
status: todo
phase: 1
owner: mac-host-dev
depends_on: [T-014]
decisions: [0002]
files:
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeHost/VirtualDisplay.swift
  - host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Sources/MateBridgeApp/DumpVideoCommand.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/
---

## Amaç

Tablette 60 fps içerik ~57 fps geliyor (NOTES 2026-09-29, T-016 ölçümleri). Test sayfasının kendisi de Mac'te 56–57 fps gösteriyor: kareler Mac tarafında, gönderilmeden önce kayboluyor. Hedef: nerede kaybolduğunu ölçmek ve 60 fps içeriğin 60 fps'e yakın ve düzenli çıkmasını sağlamak.

## Kabul kriterleri

- [ ] **Ölçüm:** host saniyede bir `component=video ev=cadence` logu yazar: SCK kare varış aralığı p50/p95/p99 ve >1,5×hedef aralık sayısı, SCK'nın bildirdiği kare durumları (complete/idle/blank/suspended…) sayıları, kodlayıcıya giren/çıkan kare sayısı, kodlama süresi p50/p95, `pending` slot üzerine yazılan (en yeni kazanır) kare sayısı, kuyruk atmaları, gönderilen kare sayısı. Saf istatistik kısmı Core'da ve testli. Menüdeki özet satırına "cap fps / enc fps / sent fps" eklenir.
- [ ] **Sanal ekran yenileme hızı:** `VirtualDisplay` modu 60 ve 120 Hz ile oluşturulabilir (ayar/ortam değişkeni/komut satırı, varsayılan 60). 120 Hz sanal ekranda SCK `minimumFrameInterval` 1/60 olarak kalır (tablete giden en fazla 60 fps). Seçilen mod ve gerçekten uygulanan yenileme hızı loglanır.
- [ ] `--dump-video` aynı ölçüm özetini yazdırır ve `--refresh 60|120` alır; orkestratör Safari 60 fps animasyon sayfasıyla iki modu karşılaştırır.
- [ ] Kodlayıcı ayarları gözden geçirilir: `ExpectedFrameRate`, `MaxFrameDelayCount` (0/1), gerekirse `RealTime`; her birinin uygulanıp uygulanmadığı loglanır.
- [ ] `./scripts/check.sh` geçiyor.

## Notlar

- Ölçüm önce: kaybı açıklayan veri olmadan ayar değiştirme. Bulguları Handoff'a yaz.
- Tablet tarafı (T-016): HarmonyOS video yüzeyinde 60 Hz'e kilitli; tablet tarafında kare temposu için şu an yapılacak iş yok.

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
