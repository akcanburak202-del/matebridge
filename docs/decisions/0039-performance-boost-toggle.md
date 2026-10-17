# 0039 — "Performans artışı" panel anahtarı (fling boost), varsayılan kapalı

- **Durum:** kabul (2026-10-17)
- **Tarih:** 2026-10-17

## Bağlam

T-319 cihazda gösterdi: video akarken görünmez bir `OverScroller.fling` (her 1 sn) Huawei iAware dokunma yükseltmesini tetikliyor. DDR 1536 MHz'e, GPU 404 MHz'e çıkıyor. 60 fps'te çözme süresi 15,6 ms'den 12,0 ms'ye, `cap_dec` −5 ms, tablet işlemci süresi %77'den %31'e düşüyor. Pil ve ısı bedeli ölçülmedi (T-320 pil A/B'si bekliyor). Kullanıcı (2026-10-17) ölçümden önce kullanımda nasıl hissettirdiğini görmek istedi ve açıp kapatabileceği bir anahtar istedi.

## Karar

- Normal panelde bir **"Performans artışı"** anahtarı olur. **Varsayılan kapalı.**
- Açıkken yalnız bu koşullarda çalışır: video akıyor, uygulama ön planda ve oturum uzak oturum değil. Mekanizma T-319'un FLING kolu, 1 sn periyot.
- Kapalıyken sıfır maliyet: iş parçacığı, zamanlayıcı ya da görünüm işi yok. Yalnız ayar okunur.
- T-319'un diğer kolları (iaware*, sustained, adpf, gpukeep…) main'e alınmaz. Dal yalnız ölçüm içindir.
- Varsayılanın açılması (ya da mod kapsamı, örn. yalnız Oyun) T-320 pil ve ısı ölçümünden sonra ayrı bir ek kararla olur.

## Sonuçlar

- Kullanıcı farkı hemen deneyebilir. Pil bedeli bilinmediği için varsayılan kapalı kalır.
- Huawei'ye özgü bir yan etki kullanılıyor; başka bir cihazda ya da HarmonyOS güncellemesinde etkisiz kalabilir (zararsız: yalnız görünmez bir fling).
- Yeniden düşünme koşulu: T-320 sonuçları; pil bedeli ≥ %10 ise anahtar Oyun'la sınırlanabilir ya da kaldırılabilir.
