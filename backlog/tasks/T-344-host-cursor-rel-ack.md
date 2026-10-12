---
id: T-344
title: Host — CURSOR_STATE `rel_ack_count` (işlenen POINTER_REL sayısı)
status: done
phase: 7
owner: mac-host-dev
depends_on: []
decisions: [0036, 0025]
files:
  - host-mac/Sources/
  - host-mac/Tests/
  - backlog/tasks/T-344-host-cursor-rel-ack.md
---

## Amaç

Karar 0036 v3 eki; PROTOCOL.md §4 CURSOR_STATE "Onay grubu". Dal tabanı: `task/0036-cursor-ack-integration`.

## Kapsam

1. **Kodlama/çözme:** `CURSOR_STATE` için 30 baytlık biçim (`rel_ack_count` u64, sonda). Grup `0` ise yazılmaz (22 bayt). Çözücü: 22 bayt grupsuz, 23–29 bayt protokol hatası, ≥30 bayt grup okunur. Fixture testleri: `cursor_state_ack`, `invalid_cursor_state_ack_partial`; mevcut `cursor_state*` değişmeden geçer.
2. **Onay değeri:** kontrol bağlantısı başına işlenen `POINTER_REL` mesajlarının sayısı (düğme değişimli `dx = dy = 0` mesajlar dahil), geliş sırasıyla. "İşlendi" şunlardan biri demek:
   - CGEvent enjekte edildi (konum ve düğme), ya da
   - 0025 bayat girdi kuralları ya da girdi kapısı onu attı.
   
   Kuyruktaki olay sayılmaz. Bağlantı başında `0`.
3. **Doğruluk (en önemli):** bir `CURSOR_STATE`'teki onay, aynı durumdaki `x`/`y`'nin o olayın etkisini içerdiğini garanti etmeli. Host konumu nereden okuyor (`CGEvent(source:nil).location`, kendi hesapladığı hedef, NSEvent…) ve CGEventPost'tan sonra konum okuması senkron mu? Bunu kodda ve gerekirse küçük bir yerel ölçümle doğrula; GUI penceresi açma. Sıra: onayı konumu okumadan **önce** al; ya da konumu enjekte edilen hedeften türet. Gerekçeyi Plan'a yaz.
4. **Akış:** onay değişince (yeni `POINTER_REL` işlendi) `CURSOR_STATE` mevcut "değişince gönder" yolundan gider; ayrı mesaj ya da yeni zamanlayıcı yok. Yeni kuyruk yok (sınırlı kuyruk kuralı).
5. Yerel imleç kapalıyken hiçbir şey değişmez.

## Kabul

- Birim testleri:
  - fixture'lar;
  - onay monotonluğu;
  - bayat atılan olayın onaylanması;
  - kuyruktaki olayın onaylanmaması;
  - onay ↔ konum sırası (sahte enjektörle).
- `./scripts/check.sh` geçer. Kotlin fixture kapsamı T-345 birleşene kadar düşebilir; handoff'ta yaz.
- Cihaz testi orkestratörde.

## Plan

Bulgular (kodda dogrulandi, olcum gerekmedi):
- `SessionServer` `.deliver` -> `handlers.deliver` (-> `InputController.deliver`, `queue.sync`, enjekte bitene kadar bloklar) -> `routeCursor`. Yani mesaj, imlec orneklenmeden once islenmis olur; bayat/kapi ile atilan mesaj da `deliver` icinden gecer.
- Konum `CGEvent(source:nil).location`; `CGEventPost` **asenkron**: okuma birkac ms (planner'da 100 ms lag penceresi, T-103) eski konumu verebilir. Sadece "onayi konumdan once al" yetmez: onay mesaji sayar, konum henuz icermeyebilir.
- Cozum: `RelAckBoard` (Core, kilitli). `InputController` her `POINTER_REL`'i isleyip post ettikten SONRA `notePointerRel(target:)` cagirir (target = o mesajin son post edilen fare olayinin konumu, post-clamp; atildiysa nil). Cursor kuyrugu once `read()` (sayi + yakin hedef), sonra canli konumu okur. Canli konum hedefe 1 pt yakin degilse (WindowServer yetismedi) raporlanan konum hedeftir (`position(live:reading:)`): sayi ve konum ayni ana ait olur. Baska enjeksiyon (pen/abs/pinch) hedefi siler; hedef 100 ms sonra duser (sayi dusmez).
- Sayi once okunur: sonradan islenen mesaj konumu yalniz daha yeni yapar (istemci fazlasini tolere eder); ters sira olmayan bir mesaji onaylardi.
- Akis: `CursorSnapshot.relAck` eklendi; planner `snapshot != lastSent` ile degisimi zaten gonderir (8 ms alt sinir, keep-alive ayni). Yeni mesaj/zamanlayici/kuyruk yok. Yerel imlec kapaliyken `tracking` false: ornekleme yok; yalniz kilitli sayac artar.
- Sayac `InputController.sessionStarted/sessionEnded`'de sifirlanir (kontrol baglantisi basina).
- Codex --high turu: (1) no-op/atilan mesaj bekleyen hedefi silmez, yasini da korur (`notePointerRel(target:nil)` yalniz sayar). (2) Sayi ve konum seqlock tarzi tek tutarli cift: `RelAckBoard.coherentPosition` = oku, konumu oku, sayiyi tekrar oku; degistiyse en fazla 3 kez tekrar, sonra en yeni okumanin hedefi (no-op'larda korunur) yetismemis canli konumun yerine gecer. Gerekce: enjektor tarafinda sayi+hedef zaten tek kilit altinda artiyor; alternatif (hedefi sayiyla ayni kilitte almak) tek basina canli konumun ilerlemesini onlemez, retry onu yakalar ve sinirli kalir. `CursorSampler.sample(board:)` bunu kullanir.
- Codex tur 2 (P2): retry tukenince eski kod `after` okumasini kullaniyordu; hedefi temizleyen bir PINCH ile (ack 14, konum 130) uretilebiliyordu. Simdi tahta bir `generation` sayacina sahip (her POINTER_REL, baska enjeksiyon ve reset arttirir); bir deneme boyunca degisirse tekrar, 3 retry sonunda `coherentPosition` nil doner ve `CursorSampler.sample` nil doner: o ornek ertelenir (sonraki ~8 ms poll / enjeksiyon takibi dener, sayi+konum cifti asla zorlanmaz). Normal yolda da baska enjeksiyonun iki okuma arasinda hedefi silmesi retry'a neden olur. Kalan: hedef denemeden once konumlayan enjeksiyonla silindiyse canli konum kullanilir (dogru olan o). Ertelenen ornek `cursor_stats`ta basarisiz ornek sayilir.
- Codex tur 3 (P2): yalniz konumu gercekten ayarlayan enjeksiyon hedefi siler. `InputController` artik mesaj turune degil, o mesajda post edilen olaya bakar (`.mouse` / `.tabletPoint` -> `noteOtherInjection`); pinch, scroll, tus, dugme-only olaylar tahtaya dokunmaz (hedef, yasi ve generation degismez). `penGesture`/`pinch` artik temizlemez. Kalan yaris yalniz konumlayan enjeksiyondan gelebilir; orada canli konum dogrudur.
- Codex tur 4 (tasarim degisikligi, orkestrator): "temizleme" kavrami kaldirildi (tur 1-3 kenar durumlari: no-op, pinch, release batch mouse-up). `RelAckBoard` artik SON POST EDILEN KONUMU tutar: `InputController.flush` post edilen (basarisiz olmayan) her `.mouse`/`.tabletPoint` olayinin son konumunu `notePosted` ile yazar (kaynak: rel/abs/kalem/sentetik up-down/release batch), bir sonraki post ustune yazar, hicbir sey silmez. `notePointerRel()` yalniz sayar (post'tan sonra). Ornekleme: (sayi, son konum, generation) oku, canli konumu oku, generation tekrar oku (degistiyse <=3 retry, sonra ertele); canli konum son konumdan >=1 pt uzak ve son konum <100 ms ise son konum raporlanir, degilse canli (fiziksel fare). `noteOtherInjection` kaldirildi.
- Codex tur 5: (a) gercek seqlock. `RelAckBoard.beginWrite()/endWrite()` (ic ice gecer, `writers` sayaci): `InputController.deliver` her mesajin tum islenisini sarar, `post(_:)` her post'u sarar (tum cagri yollari: flush, drainOwed, replay). Konum (`notePosted`) ve sayi (`notePointerRel`, atilan/kapi mesajlari dahil) yazma icinde guncellenir; `endWrite` generation'i arttirir. `coherentPosition`: yazma suruyorsa (iki okumadan birinde) ya da generation degistiyse retry (<=3), sonra nil = ornegi ertele. Boylece (ack=1, x=120) ve WindowServer'in post'u tahtadan once uygulamasi uretilemez. (b) `InjectToFrameProbe.noteInjection()` kancasi geri geldi: saf `PostSummary(events:failed:)` (Core) hem `pressEdge` (T-323) hem `lastLocation` (T-344) verir; `flush` ve `post` onu kullanir; testi `PostSummaryTests`.
- Codex tur 6: (1) saat artik kilidin ICINDE okunur (`stamped(nowUs:)` closure alir) ve `nowUs < targetAtUs` taze sayilir. (3) `PostSummary` esitlik yerine poster sozlesmesini kullanir: post edilen = ilk `events.count - failed.count` olay (basarisiz = son ek); [A, A] testi. (2) bilinen sinir olarak birakildi (asagida).
- Surec ici paylasim: `RelAckBoard.shared` (VideoCursorSwitch.shared kalibi); `main.swift` / `SessionServer` imzasi degismedi.

## Handoff

- Dal: `task/T-344-host-cursor-rel-ack` (taban 86dd5835). Commit SHA: dalin tepesi (`git log -1`).
- Dosyalar: `host-mac/Sources/MateBridgeCore/Protocol/CursorMessages.swift` (CursorState.relAckCount, 22/30 bayt, 23-29 hata), `.../Cursor/RelAckBoard.swift` (yeni), `.../Cursor/CursorStreamPlanner.swift` (CursorSnapshot.relAck), `host-mac/Sources/MateBridgeHost/Cursor/CursorSampler.swift`, `.../Cursor/CursorService.swift`, `.../Input/InputController.swift`, `host-mac/Tests/MateBridgeCoreTests/FixtureTests.swift` (+2 fixture), `.../Cursor/RelAckTests.swift` (yeni), bu kart.
- check.sh: Swift testleri gecti (1212 test). Not: onceki handoff'taki RelAckTests.swift ilk commit'e girmemisti; bu turda eklendi (codec, monotonluk, atilan/kuyruktaki, 0-4 lag sirasi, no-op sonrasi hedef, iki okuma arasi hareket + sinirli retry). Gradle FAIL: yalniz `FixtureTest.everyFixtureFileHasATestCase` (Kotlin tarafi `cursor_state_ack` / `invalid_cursor_state_ack_partial` icin test vakasi yok) -> T-345 birlesince duzelir; baska Kotlin hatasi yok.
- Varsayimlar: "islendi" = `InputController.deliver` icinde post'tan sonra (post basarisiz olsa da, bayat/kapi ile atilsa da sayilir; `stopped` iken sayilmaz). Hedef = o mesajin basariyla post edilen son `.mouse` olayi. Lag penceresi 100 ms (`InjectionPlanner.defaultLagWindowUs`), yakinlik 1 pt (planner ile ayni).
- Dogrulanmadi / cihazda bakilacak: gercek WindowServer gecikmesinde (ozellikle oyun/gizli imlec modunda) raporlanan konumun hedefe oturmasi ve istemcide snapback'in kaybolmasi; fiziksel fare ayni anda oynarsa <=100 ms hedef konumu raporlanir (kabul). `cursor_stats` yeni alan eklemedi.
- Not: sayi `0` iken grup yazilmaz; ilk `POINTER_REL`'den sonra her `CURSOR_STATE` (keep-alive dahil) 30 bayt.

- **Bilinen sınır:** WindowServer gecikmesi 100 ms'yi aşarsa son post edilen konum süresi dolar ve durum ack'in gerisinde bir konum raporlayabilir; sonuç tek seferlik küçük bir sıçramadır, girdi takılmaz. Uygulamanın WindowServer'ın olayı uyguladığını doğrulayan bir API'si yok; hedefi süresiz tutmak da fiziksel fare hareketlerini gizlerdi.

## Açık sorular
