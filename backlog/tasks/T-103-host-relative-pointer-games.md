---
id: T-103
title: Mac — göreli fare (touchpad/fare) oyunlarda görünmez duvara takılıyor; gerçek imleç konumundan başla, ham delta gönder
status: in_progress
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
- mutlak hareket `env.cursor`'dan etkilenmez.

**Risk (cihazda doğrulanacak).** Önceki hareket WindowServer'da henüz işlenmeden gelen sonraki mesaj eski konumu okuyabilir: hareket kaybı/ağırlık hissi. Deskflow macOS'ta aynı yöntemi kullanıyor. Kabul edildi, handoff'ta ölçüm önerisiyle not edilecek.

## Handoff

