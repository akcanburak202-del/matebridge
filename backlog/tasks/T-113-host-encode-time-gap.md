---
id: T-113
title: Mac — uygulamadaki kodlama süresi (enc_ms ~9,5 ms) yalıtılmış bench'ten (~6,4 ms) neden uzun? Ölç, nedeni bul
status: todo
phase: 5
owner: mac-host-dev
depends_on: []
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Tests/
  - docs/NOTES.md
  - backlog/tasks/T-113-host-encode-time-gap.md
---

## Amaç

Dilimli kodlama araştırması (NOTES 2026-10-02 ~00:50):
- yalıtılmış bench, 2800×1840 HEVC, `fast` profil (speed priority açık, RealTime kapalı): kodlama p50 **6,4 ms**;
- çalışan uygulamanın `ev=latency enc_ms` değeri 60 fps'te 9,4–9,8 ms.

Olası nedenler:
- gerçek ekran içeriği (sentetik metinden farklı);
- aynı anda 2 kare kodlayıcıda (in-flight kuyruğu, `enc_ms` bekleme dahil mi?);
- IOSurface/piksel biçimi dönüşümü;
- güç ve frekans durumu;
- ölçüm noktasının farkı.

~3 ms kazanç olasılığı var.

## Kabul kriterleri

- [ ] `enc_ms`'in tam olarak neyi ölçtüğü yazılır: hangi zaman damgasından hangisine, kuyrukta bekleme dahil mi.
- [ ] Uygulama **durdurulmuşken** (tek donanım kodlayıcı paylaşılmasın) A/B ölçüm yapılır:
  - mevcut `EncodeBench`/`SharpnessBench` ya da yeni bench seçeneği;
  - gerçekçi içerik (kaydedilmiş SCK kareleri ya da gerçek ekran yakalama);
  - in-flight 1 ve 2;
  - uygulamanın kullandığı piksel biçimi ve özellikler ile bench'inkiler.
- [ ] Neden bulunur ve NOTES'a yazılır. Ucuz, güvenli bir düzeltme varsa (örn. ölçüm yanlışsa düzeltme, ya da bir özellik farkı) uygulanır, ayar düğmesiyle (env) karşılaştırılabilir kalır. Büyük değişiklik gerekiyorsa ayrı kart önerilir.
- [ ] `./scripts/check.sh` geçiyor.

## Notlar

- Uygulamayı durdurmak oturumu keser. Orkestratör izin verdiğinde yapılır; sonunda uygulama yeniden başlatılır: `open build/MateBridge.app`.

## Plan

(ajan doldurur, commit eder, sonra uygular)

## Handoff
