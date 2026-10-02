# 0017 — Çizim modu: kararlı 120 fps, %90

- **Durum:** geri alındı (2026-10-03)
- **Tarih:** 2026-10-03

## Bağlam
Kalemle çizerken panel 120 Hz'e çıkıyor. Akıcı mod (120 fps, %100) tam çözünürlükte ~100–110 fps veriyor, çünkü tabletin HEVC çözücüsünün tavanı 2800×1840'ta ~110 fps (`media_codecs_performance.xml`: 1080p 258, 4K 71 fps ≈ 540–590 Mpx/s). Bu yüzden bazı kareler iki vsync kalıyor. Performans modu (%75) kararlı 120 fps veriyor ama ince çizgiler ve yazılar yumuşuyor. Hesaba göre %90 (2520×1656) ≈ 135 fps tavan, yani neredeyse tam netlikte kararlı 120 fps. Kullanıcı (2026-10-03) çizime özel kararlı 120 fps modu istedi.

## Karar
1. **Yeni görüntü modu "Çizim":** `STREAM_PREFS` fps 120, `scale_permille` 900, kimlik `drawing`. Döngü ve panel sırası: Netlik → Akıcı → Çizim → Performans → Oyun 120 → Oyun 60.
2. Akıcı ile aynı oynatma davranışı (jitter tamponu, ses, kalem izi). Oyun katmanı yok.
3. **Ölçek cihazda ölçülerek kesinleşir:** deneme için `--ei draw_scale N` (500–1000) açılış parametresi Çizim modunun ölçeğini geçici olarak değiştirir. Hedef: kalemle çizerken `shown` ≈ 120 fps, `skip_pct` düşük, çözme p95 < 8,3 ms. %90 yetişmezse %85, rahat yetişirse %95 denenir. Bulunan değer koda yazılır ve bu karar güncellenir.
4. Protokol ve host değişmez: 120 fps ve 500–1000 ölçek mevcut aralıkta.

## Sonuçlar
- Kart T-144 (tablet).
- Performans modu kalır (kullanıcı kararı, 0016 bağlamı). Çizim kararlı çıkarsa Performans'ın gereği ayrıca konuşulur.

## Sonradan (2026-10-03)
Cihaz ölçümü bağlamdaki varsayımı çürüttü: Akıcı (%100) çizimde de 120 fps'e yetişiyor (NOTES 2026-10-03 ~00:40). Kullanıcı Çizim modunu istemedi. T-144 geri alındı. Mod listesi 0016'daki gibi kalır.
