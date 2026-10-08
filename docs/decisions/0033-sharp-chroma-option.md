# 0033 — Keskin renk kenarları: kullanıcı seçeneği, varsayılan kapalı

- **Durum:** kabul
- **Tarih:** 2026-10-05

## Bağlam

T-233 (docs/research/2026-10-05-yuv444.md): tablet çözücüsü 4:4:4 desteklemiyor; host'ta luma ayarlı 4:2:0 ("sharp YUV") önerildi. T-235 `MATEBRIDGE_CHROMA` ile cihazda karşılaştırıldı (NOTES 2026-10-05 ~12:20): kullanıcı `sharp_nearest`'i en iyi buldu (Apple Music ikonu belirgin keskin, kırmızıda dikkat edince hafif pürüz kalıyor), `sharp_bilinear` ikinci; `444` tablette `no_output`. Bedel: yakalama→kodlama 6,7 → ~9,5 ms (Metal ~2,5 ms GPU). Kullanıcı: varsayılan kapalı, panelden istediğinde açar.

## Karar

- Tablet panelinde "Keskin renk kenarları" (Kapalı/Açık), varsayılan **Kapalı**, kalıcı, bütün modlarda görünür. HDR10 uygulanırken etkisiz (satır notla gri).
- Protokol: `STREAM_PREFS` dinamik aralık grubundaki `reserved` bayt `chroma` olur (`0` normal, `1` keskin). Grup `dynamic_range ≠ 0` ya da `chroma ≠ 0` ise yazılır. Eski host baytı yok sayar (eski `reserved` kuralı) → davranış normal. Fixture `stream_prefs_sharp_chroma`.
- Host: `chroma=1` → T-235'in `sharp_nearest` yolu; `MATEBRIDGE_CHROMA` ortam değişkeni önceliklidir. `sharp_bilinear` ve `444` yalnız geliştirici değeri olarak kalır.

## Sonuçlar

- Doygun renk kenarları (kırmızı ikonlar, renkli yazı) gözle görülür keskinleşir; tam 4:4:4 değildir.
- Açıkken ~3 ms ek gecikme ve küçük GPU yükü; kullanıcı seçer.
- Tekrar düşünülür: Metal geçişi 1 ms altına inerse varsayılan açık olabilir.
- **Güncelleme 2026-10-06:** varsayılan artık Keskin kenarlar (0034 eki).

**Ek (2026-10-08):** Kullanıcı kararı 2026-10-08 (T-297 ortak ayıklaması, `docs/reviews/2026-10-08/simplification.md`):
- `MATEBRIDGE_CHROMA=444` (tablette `no_output`) ve `sharp_bilinear` (kullanıcı `sharp_nearest`'i seçti) geliştirici değerleri kaldırılır.
- Kalanlar: `420`, `sharp_nearest`, ve 0034 paketli tam renk.
