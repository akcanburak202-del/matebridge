# 0007 — Kalem teması doğrulanmadan gönderilmez

- **Durum:** kabul
- **Tarih:** 2026-09-30

## Bağlam
T-025 canlı oturumunda Krita 5.3.4 ("Temel" fırça pürüzsüzleştirme) kalemin gitmediği yöne uzun düz çizgiler ("diken") çizdi. Tabletin ham kalem kaydı ile Mac'e ulaşan olaylar birebir aynıydı; yani MateBridge konum bozmuyor. Yakalanan tetikleyici kalem ucunun sekmesi: tek örneklik temas (≈8 ms, hareket yok), ≈20 ms sonra gerçek vuruş. Aynı olay dizisi Krita'ya yapay olarak verildiğinde 23 denemede 3 diken; sekme çıkarılınca 23'te 0 (NOTES 2026-09-30). Gerçek tablet sürücüleri bu kadar kısa temasları genellikle tık saymaz; bizde böyle bir süzgeç yoktu.

## Seçenekler
1. **Temas doğrulama (seçilen):** tablet teması ikinci örnek gelince ya da 10 ms dolunca gönderir; ondan önce biten temas atılır. Bedel: vuruş başında ≈3 ms gecikme.
2. Basınç eşiği (ör. <%1 hover sayılır): gecikme yok ama en hafif dokunuşlar çizmez ve daha yüksek basınçlı sekmeyi yakalamaz.
3. Yalnızca belgelemek (Krita'da pürüzsüzleştirmeyi kapat): kullanıcıya yük, başka uygulamalarda aynı sorun çıkabilir.

## Karar
Seçenek 1, istemcide (T-029). Tel biçimi değişmez; PROTOCOL.md §7 istemci yükümlülüklerine davranış notu eklendi. Kullanıcı onayı: 2026-09-30.

## Sonuçlar
- 10 ms'den kısa ve tek örnekli temaslar Mac'e hiç ulaşmaz (gerçek bir tık 30 ms'den uzundur).
- Host durumu etkilenmez: gönderilmeyen temasın bırakışı da yoktur.
- 17:33'teki bir diken bu tetikleyiciyle açıklanmadı; düzeltmeden sonra yeniden görülürse ayrı incelenir.
- **Güncelleme (2026-09-30 akşam):** düzeltme kurulduktan sonra Krita'da sekmesiz bir diken daha görüldü (NOTES). Sekme, dikenin gerekli koşulu değil; oynatma sonucu (3/23'e 0/23) büyük olasılıkla tesadüftü. Karar yürürlükte kalıyor (tek örneklik temas istenmeyen girdidir, bedeli ≈3 ms), ama gerekçesi "dikeni giderir" değil "sekmeyi süzer" olarak okunmalı. Diken ayrı bir konu olarak açık (T-025).
