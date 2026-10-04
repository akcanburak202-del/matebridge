# 0030 — Modlar sadeleşir: Günlük / Çizim / Oyun; kare hızı ve oyun çözünürlüğü ayrı ayar

- **Durum:** kabul (2026-10-04)
- **Tarih:** 2026-10-04

## Bağlam

Bugün beş görüntü modu var (`StreamMode`): Netlik (60, tam), Akıcı (120, tam), Performans (120, %75), Oyun 120 (120, %66 + oyun katmanı), Oyun 60 (60 + oyun katmanı). Kullanıcı: "çok fazla mod var, günlük kullanım, oyun ve çizim diye sadeleşsin; fps ayarı çözünürlük ayarı gibi kendi ayar kısmında olsun."

- **Performans**, tablet decoder'ının tam boyutta 120 fps'e yetişemediği varsayımıyla eklenmişti; T-144 bunu çürüttü (tam boyutta çizimde 120 fps, NOTES 2026-10-03 ~00:40).
- "Netlik/Akıcı" ve "Oyun 60/Oyun 120" aynı modun iki kare hızı.
- Oyun modunun gerçek kazancı 0029 oyun ekranı (oyun daha yüksek çözünürlükte çizer) ve bit hızı; kare zamanlaması T-211'den beri tüm modlarda aynı.
- 60↔120 değişimi Mac sanal ekranını yeniden kurar (0016); bu yüzden kare hızı nadiren değişmeli.

## Karar (kullanıcı seçimleri, 2026-10-04)

1. **Üç mod:**
   - **Günlük:** 2800×1840 Retina (HiDPI), kare hızı ayarı (varsayılan **120**), bit hızı kullanıcı ayarı.
   - **Çizim:** 2800×1840 Retina, **hep 120 fps**; geçici varsayılanlar (0014 §3 oyun katmanı gibi, kayıtlı ayarların üstüne biner, moddan çıkınca geri döner): **parmakla dokunma kapalı** (avuç teması tıklamasın; pinch/trackpad etkilenmez), **yüksek bit hızı** (Otomatik seçiliyse 60 Mbps).
   - **Oyun:** 0029 oyun ekranı (1x, "Oyun çözünürlüğü"), kare hızı ayarı (varsayılan **60**), 0014 oyun katmanı (60 Mbps, düşük gecikmeli ses, kalem izi/noktası kapalı).
2. **Kare hızı ayrı ayar:** "Kare hızı: 60 / 120" Günlük ve Oyun için; **her mod kendi kare hızını hatırlar**. Çizim'de gösterilmez (hep 120).
3. **Oyun çözünürlüğü listesi:** 1400×920 · 1848×1214 (varsayılan) · 2100×1380 · **2240×1472** (yeni).
4. **Kaldırılan:** Performans modu. Ctrl+Shift+7 döngüsü üç mod arasında döner.
5. **Kayıtlı modların geçişi:** `clarity` → Günlük 60; `smooth` → Günlük 120; `performance` → Günlük 120; `game` → Oyun 120; `game60` → Oyun 60.
6. **Tel biçimi değişmez:** mod istemcinin kavramı; STREAM_PREFS `fps`, `scale_permille = 1000`, `bitrate_kbps`, Oyun'da `display_*` (0029). Host değişmez.

## Sonuçlar

- **Kazanılan:** üç anlaşılır mod; kare hızı ve oyun çözünürlüğü kendi ayarlarında; gereksiz Performans modu kalkar.
- **Kaybedilen:** "Performans" (%75 ölçek) yolu; gerekirse geliştirici ayarıyla (`scale`) A/B için tutulabilir — kart karar verir, varsayılan yolda yok.
- **Kart:** T-223 (istemci). Cihaz kabulü kartın içinde.
- **Mevcut kararlar:** 0014 (oyun katmanı) Oyun moduna, Çizim katmanı aynı mekanizmaya; 0016 (Oyun 60/120 iki biçim) bu kararla "Oyun + kare hızı ayarı" olur; 0029 değişmez (listeye 2240×1472 eklenir).
