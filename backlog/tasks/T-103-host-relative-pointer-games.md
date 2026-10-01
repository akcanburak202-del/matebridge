---
id: T-103
title: Mac — göreli fare (touchpad/fare) oyunlarda görünmez duvara takılıyor; gerçek imleç konumundan başla, ham delta gönder
status: review
phase: 5
owner: mac-host-dev
depends_on: [T-034]
decisions: []
files:
  - host-mac/Sources/MateBridgeCore/Input/
  - host-mac/Sources/MateBridgeHost/Input/
  - host-mac/Tests/
  - backlog/tasks/T-103-host-relative-pointer-games.md
---

## Amaç

Kullanıcı bulgusu (2026-10-01): Steam'deki The Witcher 2'de fare imleci görünmez bir sınıra takılıyor. Menüde de, karakteri kontrol ederken de "duvarları" geçemiyor. Bazen ikinci bir fare imleci görünüyor.

Orkestratör teşhisi (kod okuması):
- `InjectionPlanner` (`MateBridgeCore/Input/InjectionPlanner.swift` ~205–220) göreli hareketi (`POINTER_REL`) kendi tuttuğu `cursor` (son enjekte edilen konum) üzerinden hesaplıyor.
- `Geometry.moved` hedefi ekrana kırpıyor. `mouseEventDeltaX/Y` **kırpılmış** fark olarak yazılıyor (`CGEventPoster.swift` ~190).
- Oyunlar imleci kendileri ışınlıyor (`CGWarpMouseCursorPosition`) ya da imleci ayırıp (`CGAssociateMouseAndMouseCursorPosition(false)`) yalnızca delta okuyor. Host'un modeli gerçek imleçten kopuyor.
- Model ekran kenarına ulaşınca o yöndeki delta 0 oluyor: görünmez duvar.
- Her olayda imleç modelin konumuna konuyor, oyun ise merkeze çekiyor: ikinci imleç ya da titreme.
- Gerçek fare kenarda da delta bildirir.

## Kabul kriterleri

- [ ] Göreli harekette başlangıç noktası **gerçek imleç konumu**dur: her olayda `CGEvent(source: nil)?.location` ile ya da eşdeğer ucuz bir sorguyla okunur. Sorgu başarısızsa son bilinen konum kullanılır. Sorgu, olay yolunda maliyeti ölçülerek yapılır.
- [ ] `mouseEventDeltaX/Y`, istemciden gelen **ham** göreli değerdir (hız çarpanı sonrası, kırpılmamış). Kesirli kısım biriktirilerek tam sayıya çevrilir. Konum hâlâ ekrana kırpılır.
- [ ] Gerçek imleç sanal ekran dışındaysa (başka ekran) davranış Plan'da açıklanır; mevcut ekran sınırı kuralı korunur.
- [ ] Mutlak girdiler (kalem, dokunmatik `POINTER_ABS`) değişmez.
- [ ] Sürükleme (`dragged`), tıklama konumu (`mouseButton` gerçek imleç konumunda), çift tıklama sayacı tutarlı kalır. Girdi takılı kalmaz.
- [ ] Testler:
  - sahte "imleç ışınlandı" senaryosu (dış imleç merkeze dönüyor) → delta korunur, duvar yok;
  - kenarda ısrarlı hareket → delta sıfır değil, konum kırpık;
  - kesirli delta birikimi.
- [ ] `./scripts/check.sh` geçiyor. Gerçek olay gönderilmez (cihaz testi orkestratörde, kullanıcıyla Witcher 2 ve normal masaüstü kullanımı).

## Plan

**Gerçek imleç sorgusu (Host).** `MateBridgeHost/Input/CursorLocator.swift` (yeni): `CursorLocating` protokolü ve `SystemCursor`. Bu `CGEvent(source: nil)?.location` okur: global nokta, sol üst köken, `DisplayGeometry` ile aynı uzay. Ön ölçüm bu Mac'te yapıldı (scratch benchmark, 20 000 çağrı). Kararlı durumda p50 ≈ 0.1 µs, p99 ≈ 0.15 µs. İlk çağrı tek seferlik ≈ 8–14 ms sürüyor (WindowServer bağlantısı). Bu yüzden `InputController.start()` sorguyu bir kez ısındırır. `NSEvent.mouseLocation` benzer maliyette ama Cocoa koordinatında olduğu için seçilmedi. Sorgu **yalnızca `POINTER_REL` mesajlarında** yapılır (Caps Lock örneği gibi), kalem/dokunma/kaydırma yolunda yapılmaz. `InputController` sorgu sayısını, başarısız sorguları, ortalama ve azami süreyi (µs) sayar. Bunlar `input_session_end` satırına alan olarak eklenir. Konum asla loglanmaz.

**Core.** `InjectionEnvironment.cursor: DisplayPoint?` alanı: Host'un örneklediği gerçek imleç, örneklenmediyse/sorgu başarısızsa nil. `InjectionPlanner.plan` başında:
- `DisplayGeometry.onDisplay(_:)` (yeni) gerçek imleç sanal ekranın yarı açık sınır dikdörtgeni içindeyse kırpılmış noktayı döndürür. İçindeyse ve önbellekteki `cursor`'dan her iki eksende de 1 noktadan fazla farklıysa (`cursor` yoksa her durumda) `cursor = live` olur. 1 noktadan yakınsa önbellek korunur: sistem konumu yuvarlasa bile yavaş trackpad hareketinin nokta-altı kesri kaybolmaz.
- Böylece aynı çağrıdaki göreli hareket **ve** düğme (down/up), tıklama sayacı, sürükleme gerçek imleç konumundan başlar. Hareketten sonra `cursor = target` olur, aynı mesajdaki düğme hareketin hedefinde basılır.
- Sorgu başarısızsa (`nil`) son bilinen konum kullanılır: önbellek `cursor`, o da yoksa ekran merkezi.

**Ekran dışı davranış.** Gerçek imleç sanal ekranda değilse (kullanıcı Mac faresiyle ana monitöre geçtiyse) canlı örnek **yok sayılır**. Hareket, önbellekteki son konumdan (ya da merkezden) devam eder ve imleç tablet ekranına geri gelir. Bu, T-103 öncesi davranışla aynıdır. Hiçbir olay başka bir ekrana konumlandırılmaz (mevcut ekran sınırı kuralı).

**Ham delta.** Göreli harekette `MacMouse.deltaX/Y` istemcinin ham `dx/dy` değeridir (hız/ivme istemcide uygulanmış hâli), kırpılmaz. Kesir taşıyıcı (`relCarryX/Y`) sıfıra doğru keserek tam sayı üretir, kalan (−1, 1) aralığında taşınır. Taşıyıcı `releaseAll`'da sıfırlanır. Konum yine `g.moved(...)` ile ekrana kırpılır. Mutlak hareket, pinch ve kalem yolu değişmez (delta yine kırpılmış fark). `CGEventPoster` zaten tam sayıya yuvarlıyor, değişiklik gerekmez.

**Testler** (`Tests/MateBridgeCoreTests/Input/RelativePointerTests.swift`, yeni):
- imleç her olayda merkeze ışınlanıyor → her olay merkez+d, delta d, duvar yok;
- kenarda ısrarlı hareket → delta sıfır değil, konum kırpık;
- kesirli delta birikimi (0.4 × n, negatif yön);
- 1 nokta altı canlı fark → önbellek kesri korunur;
- canlı imleç ekran dışında → yok sayılır, son konumdan devam;
- sorgu nil → son bilinen konum;
- düğme down/up ve sürükleme canlı konumda, çift tıklama sayacı;
- mutlak hareket konumu `env.cursor`'dan etkilenmez.

**WindowServer gecikmesi (orkestratör düzeltmesi, ilk incelemeden sonra eklendi).** `CGEventPost` WindowServer'da asenkron uygulanır. 120 Hz trackpad'de canlı örnek çoğu zaman **bizim** henüz uygulanmamış eski bir hedefimiz olur. Bunu benimsemek adım kaybettirir. Çözüm: planner, göreli hareketlerde gönderdiği son 8 hedefi (kırpma sonrası) sınırlı bir halkada tutar. Halka `releaseAll`'da sıfırlanır; oturum başı/sonu da `releaseAll`'dan geçtiği için orada da temizlenir. `plan` başında sınıflandırma şöyle:
1. örnek önbellek `cursor`'a < 1 pt → **current** (sistem yetişmiş), önbellek kalır;
2. halkadaki herhangi bir hedefe < 1 pt → **lag_ignored**, önbellek kalır, model devam eder;
3. hiçbiri değil → **adopted** (oyun ışınlaması / gerçek fare).

Ekran dışı ve başarısız sorgu kuralları aynı kalır. Üç sayaç `InjectionPlanner.Counters` içinde tutulur. Oturum başına fark olarak `input_session_end`'e `cursor_adopted`, `cursor_current`, `cursor_lag_ignored` alanlarıyla yazılır, konum yazılmaz. Ek testler: gecikmeli örneklerle hızlı patlamada adım kaybı yok; halkada olmayan konuma ışınlama benimsenir; halka sınırı 8; halka `releaseAll`'da ve oturum sonunda temizlenir.

**Codex incelemesi (P2 × 2) sonrası.**
1. *Eski girdiler tıklamayı saptırıyordu.* Her halka girdisi artık gönderim zamanını taşır. Saat, planner'a zaten verilen `now`: Host'ta `HostClock` (monoton host saati), testlerde sahte saat. Bir örnek yalnızca **`lagWindowUs` (varsayılan 100 ms, `InjectionPlanner.defaultLagWindowUs`, `Configuration.lagWindowUs` ile ayarlanır)** içinde gönderilmiş bir girdiyle eşleşirse gecikme sayılır. Süresi geçen girdiler her `plan` başında atılır. Eskiyen girdiler ayrıca şöyle emekliye ayrılır:
   - örnek mevcut imleçle eşleşirse ("current") halka yalnızca mevcut konuma (şimdi damgasıyla) indirilir;
   - halkadaki bir girdiyle eşleşirse ondan eski girdiler atılır (WindowServer sırayla uygular).
   Böylece pencere geçince yalnız düğme mesajları da gerçek imleç konumunu kullanır.
2. *Benimsenen başlangıç halkada değildi.* Benimsenen her canlı örnek de (zaman damgalı, aynı pencere) halkaya eklenir. İlk hareketlerimiz henüz uygulanmamışken başlangıcı göstermeye devam eden örnekler gecikme sayılır.

Bedel: Oyun her olaydan sonra imleci **aynı** noktaya eşzamanlı ışınlıyorsa ve hiçbir örnek bizim gönderimimizi göstermiyorsa, ışınlama en fazla pencere kadar (100 ms ≈ 12 mesaj) gecikme sanılır. Delta hamdır; yalnızca gönderilen konum bu sürede ışınlama noktasının önüne kayar. Herhangi bir örnek gönderimimizi gösterirse kayma hemen kesilir (REL-1). Witcher'da sorun görülürse pencereyi küçültmek (ör. 20–30 ms) ilk ayar adayıdır.

Testler:
- REL-17: 320/340/360 sonrası pencere içinde gecikme, pencere sonrası ve saniyeler sonra tıklama gerçek konumda.
- REL-18: başlangıç 300 iken üç örnek de 300 gösteriyor → 320/340/360, adım kaybı yok.
- REL-19: pencere ayarlanabilir.
- REL-1 iki ışınlama türüyle yeniden yazıldı.

## Handoff

- **Commit:** `84b8567` (uygulama), `b8436af` (WindowServer gecikme halkası), Codex P2 düzeltmeleri bu handoff güncellemesiyle aynı commit'te (`T-103: time-bound lag ring and remember adopted start`), plan: `b7f7d5e`. Dal: `task/T-103-host-relative-pointer-games`.
- **check.sh:** geçti (exit 0; host-mac 599 test / 64 suite, Android gradle, fixture ve crypto kontrolleri).
- **Dokunulan dosyalar:**
  - `host-mac/Sources/MateBridgeCore/Input/MacEvent.swift`: `InjectionEnvironment.cursor` alanı eklendi, `MacMouse.deltaX` dokümanı güncellendi.
  - `host-mac/Sources/MateBridgeCore/Input/Geometry+Display.swift`: `DisplayGeometry.onDisplay(_:)` eklendi (yarı açık sınır, kırpma).
  - `host-mac/Sources/MateBridgeCore/Input/InjectionPlanner.swift`: `adoptLiveCursor` (plan başında; current / lag_ignored / adopted ayrımı), son 8 göreli konumun (gönderilen hedefler ve benimsenen başlangıçlar) zaman damgalı halkası `recentTargets` ve `Configuration.lagWindowUs` (varsayılan 100 ms), `takeRelativeDelta` (ham delta, kesir taşıyıcı) eklendi. Halka da taşıyıcı da `releaseAll`'da sıfırlanır. `Counters` içine `liveCursorAdopted`, `liveCursorCurrent`, `liveCursorLagIgnored` eklendi.
  - `host-mac/Sources/MateBridgeHost/Input/CursorLocator.swift` (yeni): `CursorLocating` ve `SystemCursor` (`CGEvent(source: nil)?.location`).
  - `host-mac/Sources/MateBridgeHost/Input/InputController.swift`: yalnızca `.pointerRel` mesajında zamanlanmış sorgu yapılır. İlk çağrı `start()`'ta ısındırılır. `input_session_end` satırına `cursor_queries`, `cursor_query_failed`, `cursor_query_avg_us`, `cursor_query_max_us` ile oturum başına `cursor_adopted`, `cursor_current`, `cursor_lag_ignored` alanları eklendi.
  - `host-mac/Tests/MateBridgeCoreTests/Input/RelativePointerTests.swift` (yeni): REL-1…19 ve GEO-8. REL-12: gecikmeli patlamada adım kaybı yok. REL-13: halka dışı ışınlama benimsenir. REL-14: halka sınırı 8. REL-15/16: halka `releaseAll` ve oturum sonunda temizlenir. REL-17: eski girdi pencere sonrası tıklamayı saptırmaz. REL-18: başlangıcı gösteren örnekler adım kaybettirmez. REL-19: pencere ayarı.
  - `host-mac/Tests/MateBridgeCoreTests/Input/InjectionPlannerTests.swift`: PLAN-14 yeni sözleşmeye çekildi (kenarda delta artık ham, kırpılmış fark değil).
- **Sorgu maliyeti:** bu Mac'te (macOS 27) scratch benchmark, 20 000 çağrı. `CGEvent(source: nil).location` için p50 ≈ 0.1 µs, p99 ≈ 0.15 µs. Süreçteki ilk çağrı ≈ 8–14 ms (WindowServer bağlantısı), bu yüzden `start()`'ta ısındırılıyor. Çalışma anındaki değerler `input_session_end` alanlarında görülebilir.
- **Varsayımlar:**
  - `CGEvent(source: nil).location`, `CGDisplayBounds` ile aynı global uzayda (sol üst köken, nokta) çalışır.
  - Canlı örnek önbellekteki konuma her eksende 1 noktadan yakınsa önbellek korunur (nokta-altı kesir için). Bu yüzden oyun ışınlaması 1 noktanın altında kalan farkları düzeltmez; sapma en fazla 1 nokta olur.
  - Canlı örnek tüm planner çağrısı için `cursor`'a yazılır. Host bunu yalnızca `POINTER_REL` için örneklediğinden mutlak giriş (kalem, `POINTER_ABS`) pratikte değişmez. Planner'a örnek verilirse mutlak hareketin yalnızca *delta*sı canlı konumdan hesaplanır, hedefi aynı kalır (REL-9).
  - Ekran dışı: canlı imleç başka ekrandaysa yok sayılır. Hareket, sanal ekrandaki son konumdan (yoksa merkezden) devam eder ve imleç tablet ekranına geri döner. Bu T-103 öncesi davranışla aynıdır.
  - Gecikme halkası, kabul edilmiş uç durumlar:
    - Oyun imleci her olaydan sonra **aynı** noktaya (ör. merkez) ışınlıyorsa o nokta, benimsendiği an halkaya girer. Hiçbir örnek bizim gönderimimizi göstermezse sonraki ışınlamalar `lagWindowUs` (100 ms ≈ 120 Hz'de 12 mesaj) boyunca gecikme sayılır. Bu sürede gönderilen konum ışınlama noktasının önüne kayar; delta hamdır, kamera etkilenmez. Pencere dolunca nokta yeniden benimsenir. Herhangi bir örnek gönderimimizi gösterirse (oyun 60 Hz, mesajlar 120 Hz) halka emekliye ayrılır ve kayma hemen kesilir. İkisi de REL-1'de test edildi. Witcher'da konumun kayması fark edilirse ilk ayar `lagWindowUs`'yi 20–30 ms'ye indirmek.
    - Benimsenen başlangıç da halkada olduğu için başlangıcı gösteren gecikmeli örnekler artık adım kaybettirmez (REL-18). Önceki "benimseme başına en fazla bir adım" kaybı giderildi.
    - Dış hareketin hedefi tesadüfen pencere içindeki son 8 konumumuzdan birine < 1 pt yakınsa yok sayılır. Bu en fazla 100 ms sürer, sonra gerçek konum kazanır (REL-17).
    - Saat: girdiler `plan(now:)` ile damgalanır, Host'ta `HostClock.nowUs()` (monoton). `now` damgadan küçükse girdi geçersiz sayılıp atılır.
- **Test edilmedi (cihaz/orkestratör):**
  1. Witcher 2 (Steam): menüde ve oyunda duvar kalmadı mı, ikinci imleç ya da titreme kayboldu mu?
  2. Normal masaüstü kullanımı: trackpad'le yavaş ve hızlı hareket. Ağırlık hissi ya da hareket kaybı var mı? WindowServer gecikmesi halka ile ele alındı. Masaüstünde `cursor_adopted` küçük, `cursor_lag_ignored` ile `cursor_current` büyük çıkmalı. Witcher 2'de `cursor_adopted` yüksek çıkmalı.
  3. Kenarda sürükleme (dragged) ve çift tıklama, ekranın kenarında ve ortasında.
  4. Mac fizik faresiyle ana monitöre geçip tablet trackpad'ine dokununca imlecin tablet ekranındaki son konuma dönmesi.
  5. `input_session_end` satırında `cursor_query_avg_us` ve `cursor_query_max_us` değerleri, `cursor_query_failed=0` ve `cursor_adopted` / `cursor_current` / `cursor_lag_ignored` oranları.
- **Açık sorular:** yok. (Kapsam dışı not: `takePixels` scroll taşıyıcısı çok büyük değerlerde Int32 kırpma kalıntısı taşıyabilir. Protokol aralıkları bunu pratikte önlüyor, dokunulmadı.)

