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

## Ek (2026-10-04, T-223 uygulaması)

- **Çizim'de "parmak kapalı" = yalnız hareketler** (`FingerPolicy.GESTURES_ONLY`): tek parmak hiçbir şey göndermez (tıklama/sürükleme yok, avuç tıklamaz); **iki parmak sıkıştırma ve iki parmak kaydırma** Mac'e gider (tuvali yakınlaştırma/kaydırma). Kullanıcının kayıtlı "Parmak dokunmasını tamamen kapat" ayarı açıksa Çizim'de de her şey kapalı kalır.
- **Katman yalnız kendi ayarlarını geçici tutar:** Çizim'de ses ve kalem izi/noktası, Oyun'da parmak ayarı değiştirilirse kalıcı kaydedilir; geçici olan yalnız o modun üstüne bindiği ayarlardır (0014 §3).
- **Camda kalan parmak kuralı (tüm modlar):** izlenmeyen bir parmak hâlâ camdayken (ör. avuç) yeni dokunuş tıklama ya da hareket başlatmaz; tüm parmaklar kalkınca dokunma normale döner.

## Ek (2026-10-05, T-245): deneysel 2800×1840, yalnız Oyun 60

- Oyun çözünürlüğü listesine **2800×1840 (deneysel)** eklenir: 1x oyun ekranı panelin tam boyutunda (STREAM_PREFS `display_*` = 2800×1840; 0029 host kuralı `w ≤ screen_width` ile kabul eder). Gerekçe: Oyun 60'ta 2800×1840 çözme ~14 ms (60 fps bütçesinin ~%85'i, NOTES 2026-10-05 ~14:30); 120 fps'e yetmez.
- **Yalnız Oyun 60'ta geçerli.** Oyun 120'de (ya da Oyun 120'ye geçince) etkin boyut **2240×1472** olur; kayıtlı seçim korunur, 60'a dönünce 2800×1840 geri gelir. 60↔120 değişimi `fps` ile `display_*`'ı aynı tek STREAM_PREFS'te gönderir (ekran bir kez yeniden kurulur).
- Panel: Oyun 60'ta "2800×1840 (deneysel)"; Oyun 120'de düğme gri "2800×1840 (yalnız 60 fps)", dokunma bir şey yapmaz ve seçili görünen etkin 2240×1472'dir; Oyun dışında (panel Oyun'un kare hızını bilmez) "2800×1840 (deneysel, yalnız 60 fps)" seçilebilir, sonraki Oyun girişinde kurala göre uygulanır.
- Tel biçimi ve host değişmez.
