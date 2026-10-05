---
id: T-255
title: Probe (Mac) — 4:4:4 packing costs: Metal packer time, two VT sessions at 60 fps, auxiliary bitrate, reconstruction quality; v2 test clips
status: ready
phase: 6
owner: mac-host-dev
depends_on: []
decisions: [0033]
files:
  - probes/yuv444-probe/Package.swift
  - probes/yuv444-probe/Sources/
  - probes/yuv444-probe/Tests/
  - probes/yuv444-probe/README.md
  - probes/README.md
  - backlog/tasks/T-255-probe-yuv444-mac.md
---

## Amaç

`docs/research/2026-10-05-yuv444-packing.md` §7 P0 probunun Mac yarısı (M1–M4) + tablet probu (T-254) için gerçek AVC444v2 çift klipler. Hedef yalnız **60 fps** (kullanıcı 2026-10-05).

## Bağlam

- SwiftPM paketi `probes/yuv444-probe/` (check.sh probları derler; mevcut problar gibi). `android/` alt klasörü T-254'ün, dokunma. README tüm probun (iki taraf) çalıştırmasını anlatır; T-254'ün komutlarını sonradan orkestratör ekler.
- **Önce doğrula:** AVC444 v1/v2 örnek düzeni (MS-RDPEGFX 2.2.4.4/2.2.4.5 civarı, FreeRDP `prim_YUV` kaynakları) — araştırma belgesi bellekten yazdı; Plan'a kaynaklı kısa özet koy.
- **İçerik:** gerçekçi ekran sahneleri, sentetik çizim (IDE benzeri yazı, renkli ikonlar, kırmızı/mavi ince yazı, kaydırma ve durağan bölümler); pencere/sanal ekran açma.
- **M1:** Metal paketleyici (BGRA 4:4:4 → ana + yardımcı 4:2:0 görüntü; v2) GPU süresi 2800×1840 ve 1848×1214.
- **M2:** iki eşzamanlı VT HEVC oturumunun (MateBridge hızlı profili; 60 fps tempolu ve sınırsız) toplam kapasitesi ve kodlama gecikmesi; tek oturumla kıyas (M6'da tek motor: NOTES `NumberOfCores=1`).
- **M3:** yardımcı görüntünün bit maliyeti (durağan / yazı / kaydırma) aynı kalite ayarında; geri kurulmuş 4:4:4'ün Cb/Cr PSNR'ı (yazılım çözücü ya da VT çözme ile), 4:2:0 ve keskin renk (0033) ile kıyas; mümkünse görsel kırpıntı PNG'leri (`~/.cache/matebridge-tools/data/yuv444/`).
- **M4:** etiket yeniden yazımı (T-113 deseni) altında yardımcıda bit-tamlık (renk dönüşümü yardımcı verisini bozmamalı).
- **Klipler:** v2 çift klipler (`main_*.h265` + `aux_*.h265`, Annex-B, 60 fps, 2800×1840 ve 1848×1214, ~600 kare) T-254 probu için `~/.cache/matebridge-tools/data/yuv444/` altına.
- Mac'te pencere açma, sanal ekran kurma; VT kodlama serbest. adb/tablet yok.

## Kabul kriterleri

- [ ] `./scripts/check.sh` geçer (paket derlenir + testler: paketleme/geri kurma bit-tamlığı yazılım yolunda).
- [ ] M1–M4 sonuç tablosu Handoff'ta; klipler üretildi.
- [ ] Kapı yorumu: 60 fps'te iki VT oturumu + paketleyici bütçeye sığıyor mu; yardımcı bit maliyeti.

## Plan

## Handoff

## Open questions
