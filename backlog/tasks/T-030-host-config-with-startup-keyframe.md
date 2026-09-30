---
id: T-030
title: Mac — STARTUP/DECODE_ERROR keyframe isteğinde CODEC_CONFIG'i yeniden gönder (hızlı yeniden bağlanmada siyah ekran)
status: todo
phase: 2
owner: mac-host-dev
depends_on: [T-014]
decisions: []
files:
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift
  - host-mac/Tests/
  - backlog/tasks/T-030-host-config-with-startup-keyframe.md
---

## Amaç

T-028: tablet, sanal ekranın 10 sn'lik bekleme süresi içinde yeniden bağlanırsa (`display_reused`) hiç kare çözemiyor (siyah ekran; 3/3 tekrarlandı, NOTES 2026-09-30).

Kök neden (log + kod okuması; düzeltmeyle doğrulanacak):

1. Yeniden kullanılan ekranda kodlayıcı zaten çalışıyor. Yeni video bağlantısına host hemen `[CODEC_CONFIG, keyframe]` gönderiyor (`VideoPipeline.prepareForNewConsumer`), birkaç ms içinde.
2. Tablet `STREAM_CONFIG`'i UI iş parçacığında biraz **sonra** uyguluyor (`VideoRenderer.reconfigure` → `queue.reset(STARTUP, keepConfig = false)`): o ana kadar gelmiş `CODEC_CONFIG` ve keyframe atılıyor, `KEYFRAME_REQUEST(STARTUP)` gönderiliyor (host log'unda `video_streaming`'den ≈50 ms sonra `keyframe_request reason=0`).
3. Host isteğe yalnızca keyframe ile cevap veriyor. Parametre setleri değişmediği için `HEVCEncoder.handle` `CODEC_CONFIG` üretmiyor (`changed == false`). Tablet config'siz keyframe'leri çözücüye veriyor: `recv>0 dec=0`, `output_format` yok.

Yeni ekranda sorun yok, çünkü kodlayıcı yeni ve ilk karesi tabletin reset'inden sonra çıkıyor (config "değişmiş" sayılıp gönderiliyor).

## Kabul kriterleri

- [ ] `KEYFRAME_REQUEST` sebebi `STARTUP`, `DECODE_ERROR` ya da bilinmeyen ise host, zorlanan keyframe'den **önce** güncel `CODEC_CONFIG`'i yeniden gönderir (varsa). `FRAMES_DROPPED` isteğinde config gönderilmez (çözücü yeniden başlamadı; akış ortasında gereksiz config yok).
- [ ] Sıra garantisi: tüketici config'i o istekten doğan keyframe'den önce görür. Arada eski delta kareler gidebilir (istemci keyframe beklerken onları zaten atıyor), ama config ile keyframe arasına **başka bir keyframe'in config'siz düşmesi** sorun değildir; config yine de ondan önce kuyruktadır.
- [ ] Sınırlı kuyruk kuralları bozulmaz: `CODEC_CONFIG` korunur (atılmaz), kuyrukta birden fazla config birikmez (eskisi yenisiyle değiştirilir ya da birleştirilir), `awaitingKeyframe` mantığı aynı kalır.
- [ ] Parametre setleri henüz yoksa (ilk kare kodlanmadı) davranış bugünkü gibidir.
- [ ] Saf çekirdek testleri (`MateBridgeCore/Video`): STARTUP isteği → kuyrukta `[config, …, keyframe]`; art arda iki istek tek config bırakır; FRAMES_DROPPED config eklemez; dolu kuyrukta config atılmaz. `HEVCEncoder`/`VideoPipeline` tarafı derlenir ve mevcut testler geçer.
- [ ] Log: config yeniden gönderildiğinde `net`/`video` bileşeninde tek satır (`ev=codec_config_resent reason=<n>`), `docs/LOGGING.md` biçiminde.
- [ ] `./scripts/check.sh` geçiyor.

## Kapsam dışı

- İstemcideki sıralama (tablet `STREAM_CONFIG`'i video bağlantısını açmadan önce uygulamalı; PROTOCOL §3 adım 5): ayrı kart gerekirse orkestratör açar. Bu kart tek başına siyah ekranı gidermeli.
- Tel biçimi değişmez. PROTOCOL.md notunu orkestratör yazdı.
- Cihaz testi orkestratörde: `am force-stop` + 2 sn + `am start` beş kez; her seferinde `output_format` ve `dec>0`.

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
