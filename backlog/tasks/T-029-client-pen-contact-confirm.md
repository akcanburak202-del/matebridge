---
id: T-029
title: Tablet — tek örneklik kalem temasını iletme (temas doğrulama), Krita'daki "diken"in tetikleyicisi
status: todo
phase: 2
owner: android-client-dev
depends_on: [T-026]
decisions: [0007]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/input/
  - client-android/app/src/test/kotlin/dev/matebridge/client/input/
  - backlog/tasks/T-029-client-pen-contact-confirm.md
---

## Amaç

T-025 canlı oturumunda (NOTES 2026-09-30, "diken" girişleri) Krita, kalemin hiç gitmediği yöne uzun düz çizgiler çizdi. Yakalanan tetikleyici: kalem ucu "sekiyor": Android tek bir `ACTION_DOWN` ve hemen ardından (≈8 ms, arada hiç `ACTION_MOVE` yok) `ACTION_UP` veriyor, ≈20 ms sonra gerçek vuruş başlıyor. Tablet bunu olduğu gibi iletiyor (STROKE_START → `flags` temassız → STROKE_START); Krita "Temel" yumuşatmada ikinci vuruşun başında taşıyor. Aynı dizi yapay olarak oynatıldığında 23'te 3 diken, sekme çıkarılınca 23'te 0.

Karar 0007: tablet bir teması ancak **doğrulandıktan sonra** gönderir; doğrulanmadan biten temas hiç gönderilmez.

## Kabul kriterleri

- [ ] **Bekletme:** `ACTION_DOWN` temas örneği (ve DOWN olayının taşıdığı geçmiş örnekler yoksa) hemen gönderilmez, bekletilir. Temas şu durumlardan ilki olunca **doğrulanır** ve bekletilen örnek(ler) özgün zaman damgalarıyla, sırayla, `STROKE_START` ilk örnekte olacak şekilde gönderilir:
  1. aynı temastan ikinci bir gerçek örnek gelir (`ACTION_MOVE`, ya da DOWN olayının kendi içinde birden fazla örnek), ya da
  2. DOWN'dan beri `CONTACT_CONFIRM_MS` (10 ms) geçmiştir (bir sonraki `tick` ya da olayda). `tick` aralığı bunu karşılamıyorsa gerekçesiyle en yakın değeri seç ve Handoff'a yaz; bekletilen temas 20 ms'den uzun bekletilmez.
- [ ] **Doğrulanmadan biten temas:** bekletme sürerken `ACTION_UP` ya da `ACTION_CANCEL` gelirse temas **hiç gönderilmez** (ne `STROKE_START` ne bırakış). Kalem hâlâ menzildeyse o konumda hover örneği gönderilir (imleç geride kalmaz); `CANCEL` ise mevcut kural gibi `flags = 0`. Sayaç: saniyelik özet satırına `bounce_dropped`.
- [ ] **Host asla yarım durumda kalmaz:** bekletme sırasında host'a temas bildirilmemiştir; bu yüzden `releaseAll`, `reset`, cihaz ayrılması, araç değişimi ve bayatlama korumaları bekletilen örneği **atarak** çalışır, fazladan bırakış üretmez. Gönderilmiş her temasın bırakışı yine mutlaka gider (mevcut testler bozulmaz).
- [ ] **Durum tutarlılığı:** bekletme sırasında `followsPointer`, `inRange`, parmak kapısı (`lastSentMs`) ve canlılık tekrarı doğru davranır: kalem menzilde sayılır (parmak basışı başlamaz), canlılık tekrarı bekletilen temas yerine son **gönderilen** durumu tekrarlar ya da hiç tekrarlamaz; bırakış eşlemesi (cihaz, işaretçi) bekletilen temas için de çalışır. `HOVER_EXIT` erteleme kuralı (DOWN'dan hemen önceki exit'in yutulması) korunur; doğrulanmayan temasta ertelenmiş exit'in akıbeti tanımlı ve testli olmalı (kalem hâlâ menzildeyse yutulur, değilse gönderilir).
- [ ] Yinelenen örnek filtresi (T-026) ve `dup_*`/`max_batch` sayaçları doğrulanmış temaslarda eskisi gibi çalışır. Doğrulama anında bekletilen örnek ile yeni örnek **ayrı mesajlarda ya da tek mesajda** gidebilir; sıra ve `dt_us` doğru olmalı.
- [ ] Saf mantık JVM testli; en az: tek örneklik temas atılır ve hiçbir temas mesajı üretmez; DOWN+MOVE normal vuruş üretir (ilk örnek `STROKE_START`, zaman damgaları özgün); süre dolunca hareketsiz temas gönderilir; bekletme sırasında `releaseAll`/CANCEL/araç değişimi/cihaz ayrılması; sekme + hemen ardından gerçek vuruş (kayıtlı dizi: DOWN, 8 ms sonra UP, 20 ms sonra DOWN, MOVE…) yalnızca ikinci vuruşu üretir; fuzz testi (`InputFuzzTest`) değişmezleri yeni durumla da tutar. Kasıtlı bozma ile testlerin kırıldığını göster.
- [ ] `./scripts/check.sh` geçiyor.

## Kapsam dışı

- Protokol tel biçimi ve host değişmez (PROTOCOL.md §7'deki davranış notunu orkestratör yazdı).
- Basınç eşiği yok: hafif dokunuşlar kesilmez.
- Parmak dokunuşları bu kartta değişmez.

## Notlar

- M-Pencil 360 Hz: gerçek bir temasta ikinci örnek ≈2,8 ms sonra gelir; doğrulama gecikmesi normalde budur. Kalem hareketsizken de örnek gelir (`dup_pos`).
- Ölçülen sekme: DOWN basınç 76/16384, 8 ms sonra UP, arada örnek yok. 35 dakikalık kayıtta en kısa zararsız vuruş 6–8 olaydı (16–34 ms).
- Cihazda doğrulama orkestratörde: `bounce_dropped` sayacı, Mac olay kaydında tek örneklik vuruşun kaybolması, Krita'da diken.

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
