---
id: T-087
title: Mac — boşta tazeleme gerçek hatta kalite artırmıyor (222 baytlık atlama kareleri); düzelt ve ölç
status: todo
phase: 5
owner: mac-host-dev
depends_on: [T-086]
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Tests/
  - backlog/tasks/T-087-host-idle-refresh-real-refine.md
---

## Amaç

T-086 cihaz ölçümü (orkestratör, 2026-10-01 ~15:35, `MATEBRIDGE_IDLE_REFRESH_MS=300 MATEBRIDGE_IDLE_REFRESH_COUNT=6`):
- Tam ekran kayan metin 3 s oynatıldı, sonra durdu.
- Durağan bölümde host 6 tazeleme karesi gönderdi. Tablet hepsini gösterdi (`release`), ama **her biri 222 bayt** (atlama karesi gibi).
- `--sharpness-bench`'te aynı düğmelerle tazeleme kareleri 75–240 KB ve PSNR 42,5 → 46–47,6 dB.

Yani gerçek hatta (SCK tamponu `last` aynı `CVPixelBuffer`/IOSurface nesnesiyle yeniden kodlanıyor) VideoToolbox kaliteyi artırmıyor. Olası neden: aynı tampon nesnesi ya da değişmemiş IOSurface ile VT değişiklik görmüyor. Bench ise içeriği aynı ama farklı bir tampon veriyor olabilir. Önce nedeni kanıtla.

## Kabul kriterleri

- [ ] Neden kanıtlanır. `--sharpness-bench`'e gerçek hattı taklit eden bir kip eklenir: tazelemede **aynı** `CVPixelBuffer` nesnesi mi yoksa içerik kopyası mı gönderildiği seçilebilir. İki kipin kare baytı ve PSNR sonucu Handoff'a yazılır.
- [ ] Düzeltme: boşta tazelemede (yalnız tazeleme yolunda; `IDLE_REFRESH_MS>0` iken), VT'nin gerçekten yeniden kodlamasını sağlayan en ucuz yöntem kullanılır. Örnekler: son tamponun içeriğini havuzdan alınan yeni bir tampona kopyalamak (vImage/`CVPixelBufferLockBaseAddress` + memcpy ya da Metal blit), kare başına QP seçeneği, ya da başka bir VT yolu. Kopya maliyeti ölçülür (2800×1840 420f ~7,7 MB).
- [ ] Anahtar kare yeniden gönderimi (KEYFRAME_REQUEST) davranışı değişmez (anahtar kare zaten tam kodlanıyor).
- [ ] Varsayılanlar (düğme kapalı) bugünkü davranışla aynı kalır.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

(ajan doldurur, commit eder, sonra uygular)

## Handoff

