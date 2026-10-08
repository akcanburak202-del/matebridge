---
id: T-296
title: Ölçüm tabanı — tekrarlanabilir sentetik senaryolarla iki tarafın CPU, uyanma, gecikme ve pil maliyeti (kullanıcısız)
status: in-progress
phase: 7
owner: orchestrator
depends_on: []
decisions: []
files:
  - docs/NOTES.md
  - docs/research/2026-10-08-baseline.md
  - backlog/tasks/T-296-perf-baseline-kit.md
---

## Amaç

Sadeleştirme (T-297) ve optimizasyon (T-298) değişikliklerini kıyaslamak için tek bir taban. Kullanıcı onayı 2026-10-08: ölçüm tabanı, ardından paralel araştırma ve ortak ayıklama.

## Yöntem

- **Kullanıcısız ve deterministik:** Mac'te yerel HTML sahneleri tam ekran (Safari). Her kol akış başladıktan sonra 60 sn ısınma, ardından 60 sn ölçüm.
  - **S0 durağan:** düz sayfa, hareket yok. Terminal'deki dönen simge görünmez.
  - **S1 yazı/kaydırma:** sayfa saniyede 1 ekran kaydırılır.
  - **S2 video benzeri:** tam ekran 60 fps hareketli doku. YouTube ve oyunun yerine geçer, kodlayıcı ve çözücüye tekrarlanabilir yük verir.
  - **S3 kalem:** `adb shell input stylus motionevent` ile sentetik vuruşlar. Yalnızca girdi yolunun CPU'su ölçülür; gerçek kalem hissi ölçülmez.
  - **S4 Wi-Fi kopması:** tablette kalem teması tutuluyken `setsid` ile 3 sn Wi-Fi kapatılır. Host girdi bırakma zamanları ölçülür.
- **Ölçümler:**
  - tablet: iş parçacığı başına `/proc` farkı, CPU yüzdesi, uyanma/s, GC;
  - `MB/render ev=stats` gecikme medyanı ve p95;
  - Mac: MateBridgeApp, VTEncoderXPC ve WindowServer CPU (`top`), ağ baytları (`nettop -d`);
  - tablet pili: `dumpsys battery` / `batterystats`, S0 ve S2'de 15'er dk.
- Her kol USB ve Wi-Fi'de ayrı alınır. Ayarlar: Günlük 60, 2800×1840; kol sırası sabit.

## Kabul

1. `docs/research/2026-10-08-baseline.md`: senaryo başına tablo, komutlar, sürüm SHA'sı ve yeniden çalıştırma tarifi.
2. Kullanıcı gerektiren ölçümler (gerçek kalem hissi, oyun, tuş tekrarı) "sonra, kullanıcıyla" olarak listelenir.

## Plan

## Handoff

## Open questions
