# 0032 — HDR10 akış, yalnız Oyun modunda ve isteğe bağlı

- **Durum:** kabul
- **Tarih:** 2026-10-05

## Bağlam

T-226 araştırması (docs/research/2026-10-04-hdr-feasibility.md) kesin engel bulmadı; iki açık risk vardı. İkisi de 2026-10-05'te cihazda kapandı (NOTES):
- (a) Mac/oyun HDR ekranı görüyor mu: T-232 `MATEBRIDGE_VD_TRANSFER=1` ile Ekranlar'da "Yüksek Dinamik Aralık" anahtarı çıktı, RE4 HDR'yi kendiliğinden açtı, EDR başlığı 5×.
- (b) HarmonyOS 4.3 üçüncü taraf `SurfaceView`'da HDR10 gösteriyor mu: `hdr-probe` PQ klibi: katman `BT2020_ITU_PQ`, `DEVICE` (HWC), kullanıcı 1000 nit yamasını SDR beyazdan belirgin parlak gördü. `KEY_HDR_STATIC_INFO` verilmese de çözücü meta veriyi SEI'den okuyor. HLG klibini çözücü reddetti.
- Mac Main10 PQ kodlama 120 fps'te p50 5,6 ms (8-bit ile aynı).
Kullanıcı 2026-10-05 tam HDR'yi onayladı.

## Karar

- **Biçim:** HDR10: HEVC Main10, BT.2020 / PQ (ST 2084) / BT.2020 NCL, sınırlı aralık, 4:2:0, MDCV + CLL SEI (VT `HDRMetadataInsertionMode`). HLG yok.
- **Kapsam:** yalnız **Oyun modu**, panelde "HDR: Kapalı / Açık", varsayılan **Kapalı**. Günlük ve Çizim SDR kalır.
- **Protokol:** `STREAM_PREFS`'e ikinci isteğe bağlı grup `dynamic_range u8 + reserved u8` (14 bayt); `STREAM_CONFIG` HDR10'da H.273 `9/16/9`, `full_range=0`. Ayrı meta veri alanı yok. PROTOCOL.md §0x03, §0x05; fixture `stream_prefs_hdr`, `stream_config_hdr10`, `invalid_stream_prefs_hdr_partial`.
- **İstemci isteği:** yalnız ekran HDR10 bildiriyor + çözücü `Main10HDR10` bildiriyor + Oyun modu + kullanıcı açık. Aksi halde `0` (grup yazılmaz). Panel satırı koşullar yoksa gri ("Bu cihazda yok").
- **Host:** `dynamic_range=1` → sanal ekran `transferFunction=1` (T-232 yolu, yalnız `VirtualDisplay`), SCK HDR (`captureDynamicRange` HDR, `x420`, BT.2100 PQ), VT Main10 PQ + meta veri, girdi etiketlerini 2020/PQ'ya yeniden yaz (T-113 deseni). Her halkada başarısızlıkta SDR'ye düş, `ev=hdr_fallback reason=`. Değişim = ekran yeniden kurma + yeni `config_id`. `MATEBRIDGE_VD_TRANSFER` geliştirici anahtarı kalır ama `dynamic_range=1` onu gerektirmez.
- **Bit hızı:** Oyun modunun varsayılanı (60 Mbps) değişmez; ölçümde gerekirse ayrı karar.

## Sonuçlar

- HDR oyunlarda tablet OLED'inin parlaklık ve kontrast payı kullanılır.
- Bilinmeyenler (kabul kartında ölçülür): 10-bit çözme süresi ve 120 fps'te D (pacer) payı; SDR arayüz/masaüstü öğelerinin HDR akışta ton farkı (API 31'de SDR karartma yok); güç/ısı; Mac'te HDR açılınca Ekranlar ayarının oturumlar arası hatırlanması.
- Tekrar düşünülür: 10-bit çözme 120 fps'e sığmazsa (HDR yalnız Oyun 60), ya da SDR öğeler göze batarsa.
- **Güncelleme (2026-10-05, T-249):** 10-bit (Main10HDR10 PQ) çözme 8-bit ile aynı: 2800×1840'ta kapasite ~373 fps, 120 fps'te kare gecikmesi p50/p99 13,0/18,3 ms, kaçırma yok (NOTES ~18:40). "HDR yalnız Oyun 60" geri düşmesi gerekmiyor; HDR her Oyun kare hızında ve her oyun çözünürlüğünde kalır.
