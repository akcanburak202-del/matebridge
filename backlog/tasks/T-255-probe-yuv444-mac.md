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

**Düzen doğrulaması (kaynaklı, 2026-10-05).** Araştırma belgesi (§1b) düzeni bellekten yazmıştı; FreeRDP `libfreerdp/primitives/prim_YUV.c` (`general_RGBToAVC444YUVv2`, `general_ChromaV2ToYUV444`, MS-RDPEGFX 3.3.8.3.3 yorum bloğu) okundu. AVC444v2 (W%4==0, H%2==0):
- Ana görünüm = sıradan 4:2:0: Y=Y444; Cb,Cr = (çift sütun, çift satır) örnek. FreeRDP kodlayıcısı burada 2x2 **ortalama** kullanıyor (spec "even rows/even cols" der); ortalama yapılırsa çözücü o örneği tam geri kuramaz.
- Yardımcı Y: sol yarı (x<W/2) = Cb444[2x+1, y] (tüm tek sütunlar, her satır); sağ yarı = Cr444[2(x-W/2)+1, y].
- Yardımcı Cb (W/2 x H/2): sol yarı (x<W/4) = Cb444[4x, 2j+1], sağ yarı = Cr444[4(x-W/4), 2j+1]. Yardımcı Cr: sol = Cb444[4x+2, 2j+1], sağ = Cr444[4(x-W/4)+2, 2j+1] (tek satırlar, çift sütunlar; x%4==0 -> Cb düzlemi, x%4==2 -> Cr düzlemi).
- Her Cb/Cr örneği tam bir yerde (testle doğrulandı). **Araştırma belgesindeki "yardımcı Y'nin sol yarısı U'nun, sağ yarısı V'nin tek sütunları" doğru; "yardımcı U/V düzlemleri" ayrıntısı belgede yoktu, yukarıdaki.**
- v1 farkı (kullanmıyoruz): tek satırlar 8 satırlık bloklarla yardımcı Y'ye girer.

**Uygulama.** `probes/yuv444-probe` SwiftPM: `YUV444Core` (CPU referans pack/unpack, BT.709, PSNR, argüman, Metal kaynak metni, 0033 SharpYUV CPU kopyası), `YUV444GPU` (Metal paketleyici: fused ve iki geçişli; IOSurface 420f çıkışları, oturum etiketleri), `yuv444-probe` yürütülebilir: `clips` (v2 çift klip + referans PNG + meta), `pack-bench` (M1), `encode-bench` (M2), `quality` (M3), `bitexact` (M4). Ana görünüm chroma modu `pick` (tam geri kurulur) ya da `box` (2x2 ortalama; tek başına daha iyi 4:2:0; geri kurma `asIs`/`inverseBox`) ikisi de ölçülür. Testler: CPU pack/unpack bit-tamlığı, GPU çekirdeği CPU ile birebir (Metal yoksa atlanır). Sahne: sentetik IDE/belge/ikon/foto paneli; 4 faz (durağan, yazma, kaydırma, video), 600 kare, 60 fps.

## Handoff

## Open questions
