# color-range-probe (T-230)

Soru: tablette siyah 16'ya kalkıyor (Mac 0 → tablet 16). Kodlayıcının bit akışında siyah gerçekten Y=0 mı, SPS VUI `video_full_range_flag` ve renk açıklaması ne diyor? Ürün kodu değildir.

Probe, `HEVCEncoder`'ın oturum ayarlarını (`.fast` profil, HEVC Main, 709/sRGB/709 oturum renkleri, T-113 yeniden etiketleme) taklit eder. Bilinen bant deseniyle (Y = 0, 8, 16, 32, 64, 128, 235, 255; Cb = Cr = 128) doldurulmuş 2800×1840 bir `CVPixelBuffer`'ı birkaç kare kodlar, SPS VUI'yi ayrıştırır ve Mac'te VideoToolbox ile `420f`, `420v` ve yerel biçimde geri çözer. Çözücü VUI'ye uyan biçimde (`full=1` → `420f`) kodlanmış örnek değerlerini aynen verir.

## Ne neye dokunur

Donanım HEVC kodlayıcısını yapılandırma başına birkaç kare (varsayılan 3) kullanır. **Pencere yok, sanal ekran yok, ScreenCaptureKit yok, ağ yok.** `.hevc` (Annex-B) dosyalarını `~/.cache/matebridge-tools/data/color-probe/` altına yazar.

## Çalıştırma

```bash
cd probes/color-range-probe
swift build -c release
.build/release/color-range-probe                        # beş yapılandırmanın hepsi
.build/release/color-range-probe --only prod,noretag --frames 5 --out /tmp/x
```

| Yapılandırma | Giriş | Ekler |
|---|---|---|
| `prod` | 420f | SCK ekleri (709/709/709 + sRGB CGColorSpace) → T-113 ile 709/sRGB/709 (bugünkü üretim) |
| `noretag` | 420f | SCK ekleri olduğu gibi (T-113 öncesi; VideoToolbox renk dönüşümü yapar) |
| `420v-retag` | 420v | yeniden etiketlenmiş |
| `420v-noretag` | 420v | SCK ekleri olduğu gibi |
| `420f-untagged` | 420f | ek yok |

Sonuç tablosu ve yorum: `backlog/tasks/T-230-black-level-bitstream-probe.md` → Handoff.
