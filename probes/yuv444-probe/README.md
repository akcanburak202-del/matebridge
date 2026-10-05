# yuv444-probe (T-255, tablet yarısı T-254)

Soru: tam renk (4:4:4) görüntüyü AVC444v2 düzeniyle iki 4:2:0 HEVC akışında (ana + yardımcı) taşımak Mac'te bütçeye sığar mı, yardımcı kaç bit ister, geri kurulan renk ne kadar iyi? Arka plan: `docs/research/2026-10-05-yuv444-packing.md`. Ürün kodu değildir.

Hepsi komut satırı: pencere, sanal ekran, yakalama yok; yalnız Metal compute ve donanım HEVC kodlayıcı/çözücü. MateBridge host'u akış yaparken çalıştırmayın (kodlama motoru paylaşılır, sayılar bozulur).

## Düzen (AVC444v2, MS-RDPEGFX 3.3.8.3.3; FreeRDP `prim_YUV.c`)

`W % 4 == 0`, `H % 2 == 0`. Ana görünüm: sıradan 4:2:0 (Y = Y444; Cb/Cr = çift sütun/çift satır örnek, ya da 2x2 ortalama = `box`). Yardımcı görünüm (o da 4:2:0):

- yardımcı Y: sol yarı (x < W/2) = Cb444[2x+1, y], sağ yarı = Cr444[2(x-W/2)+1, y] (tüm tek sütunlar)
- yardımcı Cb: sol yarı (x < W/4) = Cb444[4x, 2j+1], sağ yarı = Cr444[4(x-W/4), 2j+1]
- yardımcı Cr: sol yarı = Cb444[4x+2, 2j+1], sağ yarı = Cr444[4(x-W/4)+2, 2j+1]

Çözücü tarafı: tek sütunlar yardımcı Y'den, tek satırların çift sütunları yardımcı Cb/Cr'den, (çift, çift) örnek ana görünümden. Yardımcı düzlemler **veridir**: renk dönüşümü yapılmadan ham örneklenmeli.

## Derleme, test

```bash
cd probes/yuv444-probe
swift build -c release
swift test        # CPU pack/unpack bit-tamlığı + Metal çekirdeği CPU ile birebir (Metal yoksa atlanır)
```

## Komutlar (Mac)

```bash
B=.build/release/yuv444-probe
$B clips                    # -> ~/.cache/matebridge-tools/data/yuv444/ : main_/aux_ <WxH>_60.h265, ref_*.png, yuv444_*.txt
$B pack-bench               # M1: paketleyici GPU süresi (fused/iki geçişli, pick/box, yalnız-ana taban)
$B encode-bench --matrix    # M2: 1 ve 2 VT oturumu, sınırsız ve 60/120 fps tempolu (~2 dk/boyut)
$B quality                  # M3: faz başına bit maliyeti, PSNR: 4:2:0, 0033 keskin, paketli (~45 s); --main-mbps 6 daha sıkı oran
$B bitexact                 # M4: etiket yeniden yazımı altında yardımcıda bit-tamlık
$B preview --frame 200      # sahneyi PNG olarak yaz
```

Klipler: 600 kare, 60 fps, her akışta tek IDR (kare 0), Annex-B (IDR önünde VPS/SPS/PPS), aynı kare indeksi = aynı masaüstü karesi. Ana görünüm `box` (2x2 ortalama; tek başına gösterilen karede doğru 4:2:0). Sahne dört faz: durağan (0-149), yazma (150-299, kare başı bir harf), kaydırma (300-449), video (450-599, foto paneli kayar; `--grain` kıpırtı miktarı, klipte 14). Bit hızı hedefi ana 40 Mbps (2800×1840; alanla ölçeklenir), yardımcı yarısı; kodlayıcı hedefin altında kalır (gerçek ortalama `yuv444_*.txt`'de). Her klibin metası ve düzen özeti aynı dizinde `yuv444_<WxH>_60.txt`.

Tablet tarafı (T-254, `android/` altında) komutlarını orkestratör sonradan buraya ekler.

## Notlar

- `SharpYUVReference.swift`, host'taki `SharpYUV.swift`'in (T-235, karar 0033) kopyasıdır (probe host-mac'e dokunmaz); 0033 ile kıyas için.
- `Quality` özelliği bu donanım oturumunda IDR boyutunu değiştirmedi (0,2 ile 0,8 aynı bayt); bu yüzden sabit kalite yerine ortalama bit hızı koşuları kullanıldı. `Quality=1.0` ise bit-tam (kayıpsız) çıktı verdi (bitexact).
