# 0034 — Tam renk (4:4:4) Günlük 60'ta: 4:2:0 içinde paketlenmiş iki akış (AVC444v2 düzeni)

- **Durum:** kabul (kullanıcı 2026-10-05)
- **Tarih:** 2026-10-05

## Bağlam

- Tablet çözücüsü HEVC 4:4:4 çözemiyor (T-233). Renk 4:2:0'da yarım çözünürlükte gidiyor; ince renkli yazı ve ikon kenarları (Apple Music ikonu, renkli kod) bulanık. 0033 ("Keskin renk kenarları") kısmi çözüm, tam 4:4:4 değil.
- `docs/research/2026-10-05-yuv444.md`, paketleme yolunu (3a) "çözücüye 2× yük, sığmaz" diye eledi. T-248/T-249 bu öncülü çürüttü: çözücü 2800×1840'ta ~356 fps.
- Yeniden tasarım `docs/research/2026-10-05-yuv444-packing.md`. Problar (NOTES 2026-10-05 ~20:55, ~21:40):
  - **Kapı 1 geçti:** Maleoon 920 GPU'su `GL_EXT_YUV_target` (ve Vulkan ycbcr) ile çözücü çıktısını bit-tam okuyor.
  - **Kapı 2 geçti:** ImageReader → GL birleştirme → SurfaceView yolu 60 fps'te akıcı, katman HWC'de (`DEVICE`), 5 dk ısınma yok. Doğru sunumla (swap interval 0 / derinlik-1) çözücü çıktısından ekrana ~21–31 ms; bu 60 Hz'te fiziksel alt sınıra yakın. T-254'teki 55–61 ms, probun duran kuyruğundan geliyordu.
  - **Çift çözme:** +2–4 ms. **Mac:** iki VT oturumu 2800×1840 @60'ta 60 çift/sn, çift 13–14 ms. 120 fps'te 2800'de sığmıyor. Kodlama motoru doluluğu ~%35 → ~%67.
  - **Kalite (Mac, yapay sahne):** RGB PSNR 4:2:0 37,5 dB, 0033 38,3 dB, paketlenmiş 4:4:4 42,7 dB. Yardımcı görüntünün bit maliyeti ana görüntünün ~%30–45'i (videoda ~%90).
- **Kullanıcı (2026-10-05):** "Günlük modda mantıklı"; 120 gerekmez; düşük çözünürlükte faydası kaybolduğu için yalnız tam çözünürlük. Mac yükü kabul edildi (mevcut yük azaltma önlemleri yeterli).

## Karar

1. **Kapsam:** yalnız **Günlük modu, 60 fps, doğal 2800×1840 HiDPI**. Günlük 120, Çizim (hep 120), Oyun ve HDR10 bu yolu kullanmaz; o modlarda renk seçeneği 0033'e (ya da normale) düşer.
2. **Panel:** "Renk" satırı üç seçenekli olur: **Normal / Keskin kenarlar / Tam renk**. 0033'ün mevcut Kapalı/Açık seçeneğinin yerini alır, kayıtlı değer taşınır. "Tam renk" yalnız Günlük 60'ta uygulanır; diğer modlarda satır notu "Tam renk yalnız Günlük 60'ta, şimdi: Keskin kenarlar". Tablet kapıları geçemezse (yetenek testi) "Tam renk" gri olur ("Bu cihazda yok"). Varsayılan **Normal** (kullanıcı: kendisi panelden seçer; kabulden sonra da değişmez).
3. **Düzen:** AVC444v2 örnek düzeni (FreeRDP `prim_YUV.c` ile doğrulandı, T-255 Plan). Ana görüntü normal 4:2:0 kare: Y + çift/çift örnekten Cb/Cr (`pick`, `box` değil). Yardımcı görüntü, geri kalan Cb/Cr örneklerini taşıyan ayrı bir 4:2:0 kare. **İki ayrı HEVC akışı:** iki VT oturumu ve tablette iki `MediaCodec`. Çift yükseklik ve tek akışta sıralı kodlama elendi (araştırma §1).
4. **Her karede yardımcı** (araştırma §6 ara yol 1): karo haritası yok, en basit doğru çözüm. Durağan ekranda zaten kare gitmez. T-253 netleştirme trenleri iki akışta da çalışır.
5. **Sunum:**
   - Ana görüntü bugünkü gecikmeyle gösterilir. Eşleşen yardımcı zamanında gelmişse tam renkle birleştirilir; gelmemişse o kare yalnız-ana (4:2:0) gösterilir. Takılma olmaz.
   - Tam renk açıkken istemci GL yolunu kullanır (ImageReader → `EXT_YUV_target` birleştirme → aynı SurfaceView). Kapalıyken bugünkü doğrudan yol değişmeden kalır.
   - GL yolu duran kuyruk oluşturmamalı: derinlik-1 ya da swap interval 0 ile `eglPresentationTimeANDROID` hedefi (T-256). Pacer ve slot mantığı (`AdaptivePacer`) korunur.
6. **Bit hızı:** yardımcıya ayrı tavan, ana hedefin %50'si. Toplam bit hızı ~1,3–1,5× olur. Wi-Fi'da yardımcının büyük karesi ana kareyle aynı ana denk getirilmez.
7. **Geri düşüş:** host, kodlama motoru yetişemezse (yardımcı kaybı sürekli %5'i aşarsa, ör. başka bir uygulama VT kullanıyorsa) ya da hata olursa normal 4:2:0'a döner, `ev=chroma_fallback reason=` loglar ve `STREAM_CONFIG`'te bildirir. Kullanıcı seçimi korunur, sonraki ekran kipi değişiminde yeniden denenir.
8. **Protokol** (orkestratör yazar, fixture'lar, Codex `--high`):
   - `STREAM_PREFS.chroma`: yeni değer `2` = tam renk. Eski host bunu `0` sayar.
   - `STREAM_CONFIG`: `reserved` → `chroma_layout u8` (`0` 4:2:0, `1` AVC444v2 iki akış).
   - `VIDEO_FRAME`: `reserved` → `view u8` (`0` ana, `1` yardımcı). `frame_seq` her akışta kendi içinde artar. Yardımcı, ait olduğu ana karenin `capture_time_us`'unu taşır; eşleme bununla yapılır.
   - `KEYFRAME_REQUEST`: sona isteğe bağlı `view u8`. Eski host bunu yok sayar ve iki akışa IDR gönderir.
   - `HELLO.capabilities` bit11 `FULL_CHROMA`: host yardımcı akışı yalnız bit11 + bu oturumdaki `chroma = 2` ile gönderir (eski istemciyi geliştirici değişkeni ya da hatırlanan tercih bozamaz; Codex T-257).
   - Fixture'lar: `stream_prefs_full_chroma`, `stream_config_packed444`, `video_frame_aux`, `keyframe_request_view`, kısa/geçersiz varyantlar.
9. **Kabul şartı (ilk cihaz oturumu, durdurma kuralı):** ürün içinde aynı oturumda doğrudan yol ↔ tam renk A/B. Ekran gecikmesi p50 ve p95'te **≤ +5 ms** ise devam. **> +10 ms** ise tam renk kapatılır, 0033 kalır. Arası kullanıcıyla konuşulur. Akıcılık (`skip_pct`) bugünkünden kötü olmamalı.

## Sonuçlar

- Günlük 60'ta renkli yazı ve ikonlar piksel düzeyinde doğru renkte görünür; HDMI'ye en yakın görüntü.
- Mac: kodlama motoru doluluğu ~%35 → ~%67 (yalnız ekranda hareket varken), GPU paketleme ~0,5–1 ms/kare. Tablet: ikinci çözücü, GL birleştirme geçişi (~3 ms), az bir güç artışı.
- Bit hızı ~1,3–1,5×; Wi-Fi'da da 60 Mbps sınırının altında kalır.
- Kod: host'ta paketleyici ve ikinci VT oturumu; istemcide ikinci çözücü, ImageReader + GL birleştirme yolu ve yetenek testi; panel. Tahmini 12–16 ajan günü, 3–4 cihaz oturumu.
- **Kartlar:**
  - A: protokol + fixture'lar (orkestratör, Codex).
  - B: host.
  - C: istemci.
  - D: panel ve ayar taşıma.
  - E: cihaz kabulü.
  - B ve C, A'dan sonra paralel yürür.
- **Tekrar düşünülür:** kabul şartı tutmazsa. Kullanıcı 120'de de isterse (ara yol 2/3, karo haritası). Mac kodlama motoru başka işlerle sık çakışırsa.
