---
id: T-255
title: Probe (Mac) — 4:4:4 packing costs: Metal packer time, two VT sessions at 60 fps, auxiliary bitrate, reconstruction quality; v2 test clips
status: done
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

Commit: b36b70e · Dosyalar: `probes/yuv444-probe/**` (Package, 3 hedef: Core/GPU/yürütülebilir, testler, README), `probes/README.md`, bu kart. Klipler `~/.cache/matebridge-tools/data/yuv444/`: `main_/aux_ 2800x1840_60.h265` ve `1848x1214_60.h265` (600 kare, tek IDR, Annex-B), `ref_*.png` (faz ortası kareleri), `yuv444_*.txt` (meta/düzen). `swift test`: CPU pack/unpack bit-tam, Metal çekirdeği (fused ve iki geçişli) CPU ile birebir.

**Önemli koşul:** ölçümler sırasında `MateBridgeApp` (pid 17851, 6,5 saat açık, ~%14 CPU) ve sistem yükü ~7 vardı; ben dokunmadım. M2 sayıları bu yüzden temkinli okunmalı; boşta bir makinede `encode-bench --matrix` yeniden koşulmalı. Tek oturum tavanı burada ~110 kare/sn (2800×1840) çıktı, NOTES'taki 167 `--encode-bench max` değerinden düşük.

**M1 paketleyici GPU süresi** (µs, p50/p95/p99, 400 tekrar, kaydırma sahnesi):

| Boyut | yalnız-ana (taban) | fused v2 box | fused v2 pick | iki geçişli box |
|---|---|---|---|---|
| 2800×1840 | 303 / 875 / 1281 | **486** / 1260 / 1862 | 517 / 1334 / 2049 | 608 / 1553 / 2146 |
| 1848×1214 | 122 / 405 / 808 | **182** / 584 / 1165 | 183 / 622 / 1251 | 273 / 727 / 1409 |

Paketleyici <1 ms (p50), yardımcıyı eklemenin bedeli ~+0,2 ms; fused iki geçişliden hızlı. (0033'ün ~2,5 ms'lik çekirdeğinden çok ucuz: luma ayarı yok.)

**M2 iki VT oturumu** (box, ana 40 / yardımcı 20 Mbps hedef, `maxInFlight=2`, yeni kare kazanır; 8 s pencere):

| Boyut | koşul | tamamlanan/sn | düşen | enc gecikme p50/p95 (ms) | çift gecikme p50/p95 (ms, paketleme dahil) |
|---|---|---|---|---|---|
| 2800 | 1 oturum sınırsız | 111 | - | 17,6 / 24,3 | - |
| 2800 | 2 oturum sınırsız | 61,5 çift/sn (123 kodlama/sn) | - | 33,9 / 36,1 | 50,6 / 56,9 |
| 2800 | 1 oturum @60 | 60 | 0 | 6,4 / 12,8 | - |
| 2800 | 2 oturum @60 | 59,3 / 53,6 (çift 53,2) | ana 4, yardımcı 50 | 25,9 / 31,1 ; yrd 30,8 / 35,2 | 32,6 / 36,8 |
| 2800 | 1 oturum @120 | 107,8 | 97 | 14,0 / 17,4 | - |
| 2800 | 2 oturum @120 | 55 / 53 (çift 15,9) | ana 515, yrd 534 | 31,5 / 35,1 | 35,9 / 38,8 |
| 1848 | 1 oturum sınırsız | 205 | - | 12,2 / 12,7 | - |
| 1848 | 2 oturum sınırsız | 106 çift/sn | - | 18,0 / 24,6 | 28,9 / 30,9 |
| 1848 | 2 oturum @60 | 60,1 / 60,1 (çift 60,1) | 0 | 3,4 / 3,9 ; yrd 6,1 / 6,2 | **7,0 / 8,3** |
| 1848 | 1 oturum @60 | 60,1 | 0 | 3,5 / 4,4 | - |
| 1848 | 2 oturum @120 | 111 / 96 (çift 88) | ana 67, yrd 192 | 13,0 / 16,9 | 15,6 / 18,9 |

Okuma: iki oturum **toplam** kodlama verimini artırmıyor (2800: 111 → 2×61,5; 1848: 206 → 2×106), yani tek motor, beklenen. 1848×1214'te 60 fps iki oturum rahat (çift gecikme p95 8 ms, düşme yok). 2800×1840'ta 60 fps iki oturum **sınırda** (yardımcıda %9 düşme, gecikme 26-35 ms): bu ölçümde motor ~110 kare/sn verdiği için 2×60=120 > 110; NOTES'taki 167 doğruysa (boşta makine) ~%72 ve sığar. 120 fps'te iki oturum hiçbir boyutta tam sığmıyor (2800: çift 16/sn; 1848: ~88/sn).

**M3 bit maliyeti** (kare başı, IDR hariç; 60 fps; hedef 40/20 Mbps ve sıkı 6/3 Mbps koşusu; sentetik sahne `--grain 4`):

| Faz | ana kB | yrd kB | yrd/ana | yrd Mbps@60 | (6/3 Mbps) yrd/ana |
|---|---|---|---|---|---|
| durağan | 4,8 | 1,5 | 0,32 | 0,7 | 0,60 |
| yazma | 0,6 | 0,4 | 0,76 | 0,2 | 0,95 |
| kaydırma | 9,1 | 2,6 | 0,28 | 1,2 | 0,42 |
| video (foto kayar) | 15,1 | 6,6 | 0,44 | 3,2 | 0,92 |

IDR: ana 209 kB, yardımcı 77 kB. Yardımcı çoğu içerikte ana görünümün ~%30-45'i (ana kare boyutu 2800'de ham 4:2:0'dan hep küçük); sıkı orantıda ve çok hareketli içerikte ~%90'a çıkar. Aynı sahne `--grain 14` ile klipte: ana 8,7 Mbps, yardımcı 6,6 Mbps ortalama (video fazı kare başı 55/49 kB). Yazma fazında kare başı <1 kB: tek harf için bile yardımcı ana ile aynı büyüklükte.

**M3 kalite** (PSNR dB, 4 örnek kare ortalaması; RGB = kaynak sRGB'ye karşı; "kenar" = renk kenarı pikselleri):

| Şema | sıkıştırma öncesi RGB / Cb / Cr / kenar Cb,Cr | sıkıştırma sonrası (40/20 Mbps) RGB / Cb / Cr / kenar | sıkı 6/3 Mbps RGB / Cb / Cr / kenar |
|---|---|---|---|
| düz 4:2:0 (box, nearest) | 38,2 / 41,8 / 39,1 / 27,9, 24,8 | 37,5 / 41,4 / 38,9 / 27,8, 24,8 | 35,2 / 40,3 / 38,1 / 27,1, 24,4 |
| 0033 keskin 4:2:0 | 38,3 / 41,8 / 39,1 / 27,9, 24,8 (Y 48,8) | (aralıklı IDR testi: 38,1) | - |
| paketli box, as-is | 44,1 / 47,8 / 45,2 / 33,9, 31,0 | 40,5 / 44,8 / 43,1 / 32,3, 29,9 | 36,7 / 42,3 / 41,1 / 30,4, 28,4 |
| paketli box, ters filtre | 53,7 / 59,1 / 59,2 / 53,7, 53,7 | 39,6 / 43,2 / 42,9 / 33,6, 32,7 | 34,8 / 39,0 / 38,3 / 28,6, 27,3 |
| paketli **pick**, as-is | **tam (RGB 57,9 = 4:4:4 tavanı)** | **42,7 / 47,6 / 47,1 / 37,4, 36,3** | **37,5 / 43,6 / 43,1 / 32,6, 31,5** |

Okuma: (1) 0033, RGB PSNR'ı ölçülebilir artırmıyor (38,2→38,3; renk kenarı ölçüsü luma ayarından değil kroma çözünürlüğünden geliyor), paketleme kenar Cb/Cr'ı ~+6 dB (box) / ~+10-12 dB (pick) iyileştiriyor. (2) **`pick` en iyi ve ürün için önerilen mod:** geri kurma tam, ters filtre yok; `box` + ters filtre sıkıştırma gürültüsünü 4× büyütüp kodlama sonrası `as-is`'in altına düşüyor. Bedel: `pick` ana görünümü tek başına bakıldığında takma adlı (top-left siting) bir 4:2:0; tek başına yardımcısız kare gösterilirse (hareket sırasında) biraz kötü, ana-yalnız ölçümü `pick` için yapılmadı (`box` ana-yalnız: RGB 37,5). (3) Yerel Main444 ile kıyas yapılmadı. (4) Aynı-kalite IDR testi anlamsız çıktı: VT `Quality` özelliği kabul edildi ama IDR boyutu 0,2/0,4/0,6/0,8'de aynı (~950 kB, luma 53,7 dB); o çıktıdaki kalite sayıları ("intra" bölümü) yalnız kıyas için; IDR'de yardımcı ana'nın %62'si, toplam 1,62×.

**M4 bit-tamlık** (1280×720 desen + gerçek yardımcı + gerçek ana, `Quality=1.0`; 1 IDR + 2 P): oturum etiketleriyle yeniden etiketlenmiş **ve** hiç etiketsiz tampon: 3 test girdisinde %100 bit-tam (maks hata 0; `Quality=1.0` bu donanımda kayıpsız). SCK benzeri etiketler (709 aktarım): desende %3,8 örnek tam, maks hata 118; gerçek yardımcıda Y maks 45, Cb 75, Cr 63, %26 tam; BT.601 matris: maks 33; BT.2020/PQ: maks 150. Yani VT, etiketi oturumdan farklı tamponu renk dönüşümüne sokup yardımcı veriyi bozuyor; T-113 yeniden etiketlemesi (ya da etiketsiz) yardımcıyı bozmuyor. Paketleyici çıkışını oturum etiketleriyle işaretliyor (`SessionTags`).

**Kapı yorumu (60 fps):** paketleyici bütçeye rahat sığar (<1 ms p50, p99 <2,1 ms). İki VT oturumu: 1848×1214'te sığar (çift gecikme p95 8 ms, +3-4 ms ana'ya göre), 2800×1840'ta ölçüldüğü koşulda sınırda (motor ~110 kare/sn; 120 = 2×60 fazla). Boşta makinede (tek oturum >=167 beklenir) ~%72 ile sığması mümkün; yeniden ölçüm şart. 120 fps'te sığmıyor. Yardımcı bit maliyeti ana'nın ~%30-45'i (sıkı oranda/video'da ~%90), yani toplam bit hızı ~1,3-1,9×.

**Varsayımlar / test edilmeyenler:** (a) M2 kirli ortam (yukarıda). (b) Yardımcı Y düzeni FreeRDP kaynağından (WebFetch özeti), MS-RDPEGFX metninden doğrulanmadı; tablet tarafı klibi kendi okuyuşuyla aynı aldığını doğrulamalı. Araştırma belgesinde yardımcı U/V düzlemlerinin ayrıntısı yoktu; yukarıdaki Plan'da yazılı. (c) VT decode Mac donanım çözücüsüyle, tablet çözücüsü değil. (d) Sahne sentetik (ekran görüntüsü değil); gerçek masaüstünde bit oranı farklı olabilir. (e) Karo farkı (dirty tile) çekirdeği ve v1 düzeni yapılmadı (kart yalnız v2). (f) Yerel Main444 PSNR karşılaştırması yok. (g) Kullanılmayan GPU test/ölçüm: ısı `nominal`.

## Open questions

- M2'nin boş makinede tekrarı (orkestratör host'u kapatınca): `yuv444-probe encode-bench --matrix`. Tek oturum 2800'de ≥150 kare/sn çıkarsa 60 fps çift sığar.
- Karar kuralı (araştırma §7): çift gecikme p95 ≤ +4 ms ölçütü tablet tarafı (T-254) ile birleşince değerlendirilecek; Mac tarafında 1848'de ana'ya göre +3-4 ms (p50), 2800'de belirsiz.
