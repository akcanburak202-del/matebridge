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
- **Güncelleme (2026-10-06, T-280, kullanıcı kararı):** HDR anahtarı **Günlük** modunda da var (film/video izlemek için; Oyun modunda masaüstü hoş görünmüyor). Ayar mod başına ayrı ve kalıcı: Oyun'un mevcut "HDR" ayarı aynen kalır, Günlük'ün ayrı "HDR" ayarı varsayılan **Kapalı**. Bu sayede Oyun'da açık HDR Günlük'e geçince masaüstünü griye çevirmez. Çizim SDR kalır. Günlük + HDR10'da renk seçeneği (Keskin / Tam renk) etkisizdir (0033/0034 kuralı: HDR10 4:2:0). Host ve protokol değişmez (host modu bilmiyor; `dynamic_range` zaten mod bağımsız). Bedel: HDR açıkken masaüstü grimsi (API 31'de SDR karartma yok); açıp kapamak ekranı yeniden kurar (kısa kararma). DRM'li servisler (Netflix, Apple TV+ vb.) ekran yakalamasında büyük olasılıkla siyah görünür; bu durum HDR'den bağımsızdır ve henüz denenmedi.
- **Güncelleme (2026-10-06, T-281):** HDR10 için kurulan sanal ekran (`tf=1`) descriptor'da **Display P3 primerleri** alır (Sidecar deseni: R 0,68/0,32 · G 0,265/0,69 · B 0,15/0,06 · W 0,3127/0,329). Gerekçe: macOS `MTShouldPlayHDRVideo` harici ekranda geniş gamut şartı arıyor, bizim ekran varsayılan 709 primerle bu şartı geçemiyordu; Safari/YouTube bu yüzden HDR sunmuyordu (araştırma `docs/research/2026-10-06-safari-hdr-virtual-display.md`). Kullanıcı Ekranlar'da profili elle Display P3 yapınca YouTube HDR göründü (2026-10-06 ~21:20). Ek kazanç: HDR akışta masaüstü birleştirmesi sRGB yerine P3 gamutunda yapılır. SDR ekranı değişmez (varsayılan primerler). Yakalama renk alanları açıkça seçildiği için tel anlamı ve protokol değişmez. Geliştirici anahtarı `MATEBRIDGE_VD_PRIMARIES=default` P3'ü kapatır.

**Ek (2026-10-08):** Kullanıcı kararı 2026-10-08 (T-297 ortak ayıklaması, `docs/reviews/2026-10-08/simplification.md`):
- `MATEBRIDGE_VD_TRANSFER` (SDR akışta tf=1 ekranı) kaldırılır; HDR10 akışı bu ihtiyacı karşıladı.
- HDR10 için aktarım işlevi ve primer kurulumu kalır.
