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

Yalnızca `PenTracker` (ve sayaçlar için `Model.kt`) değişir; `InputCapture` yalnızca bir teşhis alıcısı ekler.

1. **Bekletilen temas (`pending`):** `ACTION_DOWN` artık hemen örnek üretmez. Ham `PenPoint`'ler, DOWN olay zamanı ve DOWN'un dağıtım zamanı (`nowMs`) `Pending` içinde tutulur; örnekler (normX/Y, basınç, eğim) doğrulanınca üretilir, bu yüzden atılan temas `lastTilt`/`last`/`lastFlags`'e dokunmaz. `state` host'un bildiği durumu tutar (OUT/HOVER/CONTACT); bekletilen temas `state`'i değiştirmez.
2. **Doğrulama:** (a) aynı temastan `MOVE` gelirse bekletilen + gelen örnekler tek `emitReal` ile gider (ilk örnek `STROKE_START`, özgün zamanlar); (b) DOWN'un kendisi birden çok örnek taşıyorsa hemen doğrulanır; (c) `tick`'te `nowMs - downNowMs >= CONFIRM_MS (10)`; (d) UP / hover / ikinci DOWN olayında, olay zamanına göre (`son örnek - DOWN`) ≥ 10 ms ise önce doğrulanır, sonra olay normal işlenir.
3. **Doğrulanmadan bitiş:** olay zamanına göre < 10 ms'de UP / hover olayı ya da herhangi bir CANCEL gelirse temas atılır (`bounce_dropped++`), sonra olay mevcut kurallarla işlenir: UP -> hover örneği (kalem hâlâ orada), CANCEL -> `flags = 0`, HOVER_EXIT -> ertelenir ya da `flags = 0`. `release`, `reset`, araç değişimi bekletileni sayaçsız atar; fazladan bırakış üretilmez (host bilmiyordu).
4. **Durum tutarlılığı:** `inRange = state != OUT || pending != null` (parmak kapısı açılmaz); `followsPointer` bekletilen için de (cihaz, işaretçi) eşler; `contactDeviceId/PointerId` DOWN'da atanır, atılınca temizlenir; `lastSentMs` gönderimde güncellenir (bekletmede değişmez); `tick` bekletme sürerken canlılık/bayatlama çalıştırmaz (en çok birkaç on ms sürer, host'a bir şey bildirilmemiştir). DOWN'un yuttuğu `HOVER_EXIT`: temas atılırsa UP -> hover (yutulmuş kalır), CANCEL / hover exit / release -> `flags = 0` gider.
5. **DOWN, `state == CONTACT` iken** (kaçan UP): eski temasın bitişi (IN_RANGE örneği) hemen gider, yenisi bekletilir.
6. **Zamanlama seçimi:** `CONFIRM_MS = 10`. Gerçek temasın ikinci örneği ≈2,8 ms'de gelir (olay yolu); ölçülen sekme 8 ms. `INPUT_TICK_MS = 25` (`MainActivity`, kapsam dışı) olduğu için yalnızca zamanlayıcıya kalan hareketsiz-temas yolu en kötü ≈35 ms'de doğrulanır; kartın "20 ms" üst sınırı bu yolda `MainActivity`'de tick'i ≤5 ms yapmadan sağlanamaz (Handoff/Açık sorular).
7. **Testler:** `PenTrackerTest`'te yeni `PenContactConfirmTest` (tek örnek atılır, DOWN+MOVE, süre dolumu tick/olayla, UP/CANCEL/release/reset/araç değişimi/hover exit, exit erteleme akıbeti, kayıtlı sekme dizisi, sayaç, dt_us/zamanlar); mevcut testler yeni gecikmeye göre güncellenir; `InputFuzzTest` değişmezi `penHostInRange` ile; kasıtlı bozma ile testlerin kırıldığı gösterilir.

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
