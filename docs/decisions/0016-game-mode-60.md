# 0016 — Oyun modunun iki biçimi: Oyun 120 ve Oyun 60

- **Durum:** kabul
- **Tarih:** 2026-10-02

## Bağlam
Faz 0 ölçümleri ve T-140 (docs/NOTES.md 2026-10-02 ~21:30, ~22:45):
- Huawei AGP, panelimizi dokunma ya da işaretçi (kalem, BT fare, trackpad) yokken 60 Hz'de tutuyor. Uygulama içinden aşılamıyor.
- Panel 60 Hz iken DISPLAY_RATE geri bildirimi host'u 60 fps'e indiriyor. Klavye ya da gamepad ile oynanan oyunda Oyun modu (120 fps, %66) fiilen 60 fps verir, üstelik gereksiz %66 bulanıklıkla.
- Mac'te sanal ekran 120 Hz olduğu için oyun da boşuna 120 çiziyor.

Kullanıcı seçimleri (2026-10-02): oyun modunun iki biçimi olsun, adları "Oyun 120" ve "Oyun 60" olsun, döngüde arka arkaya gelsinler, Performans modu kalsın. Modun kendiliğinden değişmesi istenmiyor, çünkü her mod değişimi sanal ekranı yeniden kuruyor ve kısa bir kararma oluyor.

## Karar
1. **Mevcut Oyun modu "Oyun 120" adını alır.** Değeri değişmez: `STREAM_PREFS` fps 120, `scale_permille` 660. Kayıt kimliği `game` aynı kalır, yani kayıtlı mod olarak Oyun seçmiş olanlar Oyun 120'de kalır.
2. **Yeni mod "Oyun 60":** fps 60, `scale_permille` 1000, kimlik `game60`. Klavye ya da gamepad ile oynanan oyunlar için. Panel 60 Hz'de kalsa da tam çözünürlük kalır, Mac'te sanal ekran 60 Hz olur.
3. **Oyun 60, karar 0014'ün oyun davranışlarının tamamını paylaşır:** jitter tamponu 0, geçici varsayılanlar (bit hızı Otomatik ise 60 Mbps, ses "Düşük gecikme", kalem izi ve noktası kapalı), oturum katmanı kuralları ve paneldeki "(oyun modu)" işareti. Oyun 120 ile Oyun 60 arasında geçiş "oyun modundan çıkış" sayılmaz: kullanıcının o oyun oturumunda yaptığı geçici değişiklikler korunur.
4. **Döngü (Ctrl+Shift+7) ve panel listeleri:** Netlik → Akıcı → Performans → Oyun 120 → Oyun 60 → başa.
5. Protokol ve host değişmez: 60 fps ve %100 mevcut `STREAM_PREFS` aralığında.

## Sonuçlar
- Kart T-143 (tablet).
- Panel 60 Hz iken host'un yakalamayı da 60'a indirmesi ayrı konu: önce Mac'te maliyet ölçülecek.
- Tekrar düşünülür: Huawei ileride dokunmasız 120 Hz'e izin verirse (T-140 deneyi parametreyle yeniden çalıştırılabilir).

**Not (2026-10-04, karar 0029):** sanal ekran yalnız yenileme hızı değişince değil, ekran kipi (oyun ekranı piksel boyutu ya da HiDPI) değişince de yeniden kurulur; yeniden kurulum her zaman eskisini kaldırıp ~700 ms bekledikten sonra yapılır.
