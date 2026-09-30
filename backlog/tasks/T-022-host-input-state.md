---
id: T-022
title: Mac girdi durum makinesi — kalem, işaretçi, dokunma, release-all (saf, testli)
status: review
phase: 2
owner: mac-host-dev
depends_on: [T-014]
decisions: [0003, 0006]
files:
  - host-mac/Sources/MateBridgeCore/Input/
  - host-mac/Tests/MateBridgeCoreTests/Input/
---

## Amaç

PROTOCOL.md §4 (PEN durum makinesi, POINTER_*, SCROLL, PEN_GESTURE, RELEASE_ALL) ve §7'nin (girdi güvenliği) **host tarafı mantığı**, CGEvent'ten bağımsız ve tamamen birim testli. Çıktısı soyut "enjekte edilecek olaylar" listesidir; T-023 bunları CGEvent'e çevirir. AGENTS.md'nin 1 numaralı riski burada: girdi asla takılı kalmamalı.

## Kapsam dışı

- CGEvent, izinler, oturum bağlantısı (T-023). Klavye (Faz 3), trackpad göreli hareket ve hassas kaydırma (Faz 3; bu kartta yalnızca durum/sahiplik kuralları).

## Kabul kriterleri

- [x] `InputStateMachine` (Core): girdi mesajları + zaman (`now`) alır, sıralı `InjectAction` listesi üretir: proximity enter/leave (araç tipiyle), mouse down/drag/up/move (tablet-point alt tipi, basınç, eğim), buton down/up, scroll başla/değişti/bitti. Koordinat dönüşümü bu katmanda yok (normalize değerler geçer); dönüşüm T-023'te tek yerde.
- [x] PEN durum makinesi §4 tablosunun **her satırı**: `IN_RANGE`/`CONTACT` geçişleri, aynı örnekte enter+down, `CONTACT=1 IN_RANGE=0` → `flags=0`, araç değişimi (up+leave+enter), `STROKE_START`.
- [x] **Kilit (latch)**: her release-all sonrası `CONTACT=1` örnekler `CONTACT=0` veya `STROKE_START` gelene kadar hover sayılır.
- [x] **Watchdog'lar**: kalem `IN_RANGE` iken 500 ms örnek yoksa up+leave; SCROLL açıkken 500 ms mesaj yoksa bitir.
- [x] **Kaynak ayrımı / sol düğme sahipliği** (§7): tek sahip; kalem önceliği (başka kaynak basılıyken kalem teması → önce o kaynak adına up, sonra kalem down); sahip olmayan kaynağın bırakması etkisiz; kalem temas halindeyken diğer kaynakların sol basışı yok sayılır; diğer düğmeler OR; kalem `IN_RANGE` iken TOUCH yeni basışları yok sayılır ama **sahibin bırakışı asla** yok sayılmaz.
- [x] **Release-all** (her tetikleyici: mesaj, BYE, kopma, 1,5 sn sessizlik, devralma, kapanış): tüm basılı düğmeler up, kalem up+leave, scroll bitir, kilit kur. Çağrılabilir API + `releaseAll(reason)`.
- [x] **PEN_GESTURE DOUBLE_TAP → silgi modu aç/kapa** (karar 0006): silgi modunda kalem örnekleri `tool=ERASER` sayılır (araç değişimi kuralı: gerekirse up, leave, eraser olarak enter). Mod release-all ve oturum sonunda kalem moduna döner. Tabletten gelen gerçek `tool=ERASER` doğrudan silgidir.
- [x] **Parmak kapısı** (karar 0006): kalem `IN_RANGE` iken ve son kalem örneğinden sonraki 1 sn boyunca TOUCH yeni basışları yok sayılır. Sahibin bırakışı her zaman işlenir.
- [x] Testler: §4/§7'deki her kural için en az bir test; ayrıca rastgele (property/fuzz) test: rastgele mesaj dizileri + rastgele release-all sonrası **"hiçbir basılı durum kalmadı"** değişmezi ve "her down'un bir up'ı var" değişmezi.
- [x] `./scripts/check.sh` geçiyor.

## Notlar

- Kritik: bu kart Codex `--high` incelemesinden geçer.

## Plan

Tek dosya ailesi, saf ve tablo güdümlü: `InputStateMachine` (struct, `Sendable`, saat yok; `now` mikrosaniye parametre). Çıktı `InjectAction` listesi; koordinat dönüşümü yok (normalize u16 aynen geçer).

**Dosyalar** (`host-mac/Sources/MateBridgeCore/Input/`): `InjectAction.swift` (çıktı türleri), `InputStateMachine.swift` (durum + genel API: `handle(_:now:)`, `tick(now:)`, `releaseAll(_:now:)`), `InputStateMachine+Pen.swift`, `+Pointer.swift`, `+Scroll.swift`. Testler `host-mac/Tests/MateBridgeCoreTests/Input/`.

**Çıktı sözleşmesi (T-023 tüketir):** `penProximity(tool, entering)`, `penHover/penDown/penDrag/penUp(tool, PenPoint)`; `mouseMove(motion, dragging)` (imleci taşır, önce), `mouseButton(button, down)` (imlecin o anki yerinde), `scroll(phase, dx, dy)`, `scrollWheel(dx, dy)`. `PenPoint` = normalize x/y, basınç u16, ham i16 eğim. Bir mesajdaki hareket her zaman düğme geçişlerinden önce gelir.

**Durum:** kalem (etkin araç, temas, son nokta, araç başına kilit), sol düğme sahibi (`pen/rel/mouse/touch`), kaynak başına bildirilen düğmeler (`held`, release-all'da SİLİNMEZ = işaretçi kilidi) ve Mac'e katkı veren sağ/orta/geri/ileri (`contributing`, OR), açık scroll, silgi modu, son kalem örneği zamanı (parmak kapısı + watchdog), son scroll zamanı.

**Kurallar → test adı eşlemesi** (test adları kural kimliğiyle başlar; Handoff'ta tablo): PEN-1..PEN-10 (§4 tablosu satırları + STROKE_START + CONTACT/IN_RANGE=0), LATCH-*, WD-PEN, WD-SCROLL, OWN-* (§7 sahiplik), OR-*, GATE-* (parmak kapısı), REL-* (release-all her tetikleyici + idempotans), ERASER-* (karar 0006), SCROLL-*, FUZZ-* (seed'li SplitMix64; gölge Mac modeli: "her down'un up'ı var", çift down/up yok, release-all sonrası hiçbir şey basılı değil, makine durumu = modelin durumu).

**Güvenli okuma seçimleri** (PROTOCOL belirsiz olan yerler, Handoff'ta işaretlenecek): (1) release-all sonrası işaretçi kaynaklarının bildirilen düğme durumu korunur, yani bayat `LEFT` mesajı yeni basış sayılmaz; (2) kalem temasında sahip olmayan kaynakların imleç hareketi bastırılır; (3) araç değişiminde temas sürüyorsa yeni araç için kilit kurulur (vuruş ortası yeni vuruş olmaz); (4) temas sürerken gelen ikinci `STROKE_START` = up + down; (5) DOUBLE_TAP silgi modunu çevirir, araç değişimi bir sonraki kalem örneğinde uygulanır.

Sıra: önce bu plan commit'i, sonra kod + testler, `check.sh`, Handoff.

## Handoff

- **Commit:** kod `d5cb30d` + `bb527ce` (dal `task/T-022-host-input-state`); en üstteki commit yalnızca bu kartı günceller. `./scripts/check.sh`: ALL OK (Core 156 test).
- **Dokunulan dosyalar:** `host-mac/Sources/MateBridgeCore/Input/{InjectAction,InputStateMachine,InputStateMachine+Pen,InputStateMachine+Pointer,InputStateMachine+Scroll}.swift`; `host-mac/Tests/MateBridgeCoreTests/Input/{InputTestSupport,PenStateTests,PointerOwnershipTests,SafetyTests,InputFuzzTests}.swift`; bu kart. Başka dosyaya dokunulmadı; protokol/fixture değişmedi.
- **T-023 için API özeti:**
  - Oturum başına bir `InputStateMachine` (değer tipi, kilitsiz; tek kuyruktan kullanılır). `handle(_ message, now:)` (yalnızca `deliver` edilen girdi mesajları; KEY ve diğerleri `[]`), `tick(now:)` (watchdog'lar), `releaseAll(_ cause: ReleaseCause)` (`SessionAction.releaseInput`'un nedeni doğrudan geçer). `nextDeadline` bir sonraki watchdog anını verir. `now` = `HostClock.nowUs()` (SessionMachine ile aynı saat). `handle(.releaseAll/.bye)` da release-all yapar.
  - `InjectAction`: `penProximity(tool, entering)`, `penHover/penDown/penDrag/penUp(tool, PenPoint)`, `mouseMove(MouseMotion, dragging: MouseButton?)`, `mouseButton(MouseButton, down:)`, `scroll(phase, dx, dy)`, `scrollWheel(dx, dy)`. Liste sırayla uygulanır. `PenPoint` normalize u16 x/y, u16 basınç, ham i16 eğim (`tiltXUnit`/`pressureUnit` yardımcıları var).
  - Enjektör kuralları: `mouseButton` imlecin O ANKİ konumunda uygulanır (aynı mesajın önceki `mouseMove`'u konumu belirler; kalem önceliği ve release-all up'ları için enjektörün son konumu tutması gerekir). `mouseMove.dragging` ilgili `*MouseDragged` tipini seçer (nil = `mouseMoved`). `penUp` basıncı 0'dır. `.scroll(.cancelled)` momentumsuz kapatma demektir (istemci `ENDED`'i `.ended`, geri kalan zorunlu bitişler `.cancelled`). Çift tıklama `clickState` enjektörde.
  - Taze bir makinede `releaseAll` çağrısı yalnızca kilidi kurar; oturum yeniden bağlanırken vuruş ortasından başlama riski görülürse T-023 bunu kullanabilir.
- **Kural -> test eşlemesi** (test adları kimlikle başlar, `swift test` çıktısında görünür):

  | Kural | Testler |
  |---|---|
  | §4 enter / down / drag / up / hover / up+leave sırası | PEN-1..7, PEN-12 |
  | §4 araç değişimi (up + leave + enter) | PEN-8a/b/c, ERASER-3/4 |
  | §4 `CONTACT=1 IN_RANGE=0` -> `flags=0` | PEN-9a/b/c, LATCH-6 |
  | §4 `STROKE_START`, aynı örnekte enter+down | PEN-3, PEN-10, LATCH-3 |
  | §4 kilit (her release-all sonrası, araç başına) | LATCH-1..7, REL-7, FUZZ-3 |
  | §7 kalem watchdog 500 ms | WD-PEN-1..6, WD-5 |
  | §7 scroll watchdog 500 ms | WD-SCROLL-1/2, WD-3 |
  | §7 tek sol düğme sahibi, sahip olmayanın basış/bırakışı etkisiz | OWN-1, OWN-4, OWN-5 |
  | §7 kalem önceliği (önce sahip adına up, sonra kalem down; yeniden basmak gerekir) | OWN-2, OWN-2b |
  | §7 kalem temasında diğer sol basışlar yok sayılır | OWN-3, OWN-3b, OWN-6 |
  | §7 diğer düğmeler OR | OR-1..8 |
  | §7 + karar 0006 parmak kapısı (IN_RANGE + 1 sn; sahibin bırakışı hep işlenir) | GATE-1..8, OR-6/7 |
  | §7 release-all (12 `ReleaseCause`, mesaj, BYE), idempotans, sıra | REL-1..10, LATCH-5 |
  | Karar 0006 çift dokunma silgi modu; release-all'da kalem moduna dönüş | ERASER-1..7 |
  | §4 SCROLL host kuralları | SCROLL-1..5, REL-8 |
  | "Hiçbir basılı durum kalmadı" + "her down'un up'ı var" | FUZZ-1 (500 seed x 200 adım, bağımsız Mac modeli), FUZZ-2 (20 000 adım, sayaç dengesi), FUZZ-3 (bayat tekrar), FUZZ-4 (determinizm) |

  Testlerin gerçekten hata yakaladığı elle doğrulandı: 11 mutasyon (kilit yok, release-all scroll'u açık bırakır, sahip olmayan bırakır, release-all bildirilen düğmeleri siler, kalem önceliği up'ı yok, kapı süresi yok, watchdog up'sız, kapıdayken sahibin bırakışı yok sayılır, bayat temas hover olmaz, leave up'sız, release-all diğer düğmeleri bırakmaz) her biri en az 1, çoğu 5-9 testte kırmızı verdi; sonra geri alındı.
- **Varsayımlar (PROTOCOL/karar sessiz ya da belirsiz; "girdi asla takılı kalmaz" için en güvenli okuma seçildi):**
  1. **İşaretçi kaynaklarında release-all sonrası kilit.** §4 kilidi yalnızca kalemi kapsar. POINTER_* için "önceki durum" release-all sonrası belirsiz; bayat `LEFT` (sürükleme ortası) mesajı yeni basış sayılmasın diye kaynağın bildirdiği düğme durumu (`held`) release-all'da SİLİNMEZ. Yeni basış için kaynağın önce bırakması sonra basması gerekir (FUZZ-3, REL-5/6). Bedeli: istemci bırakışı göndermeden kendi durumunu sıfırlarsa bir tıklama kaybolur. **Orkestratör onayı / protokol notu gerekebilir.**
  2. **Watchdog kilit kurmaz.** §4/§7 yalnızca release-all sonrası kilit diyor; watchdog kapatması `flags=0` sayar. Sonuç: watchdog vuruşu kapattıktan sonra gelen vuruş-ortası `CONTACT` örneği tabloya göre yeni bir down olur (LATCH-8). Takılı kalmaz (bırakışı arkasından gelir; yoksa watchdog/release-all). İstenirse watchdog'a da kilit eklemek tek satır.
  3. **Araç değişimi vuruş ortasındaysa** (yeni araçta `CONTACT` var, `STROKE_START` yok) yeni araç kilitli başlar (hover): vuruş yeni araçla devam etmez (PEN-8c, ERASER-4). Gerçek araç değişimi `STROKE_START` taşır ve normal başlar (PEN-8b).
  4. **Temas sürerken ikinci `STROKE_START`** = önce up sonra down (yeni vuruş; PEN-10).
  5. **Enter örneği konumu da bildirir:** `IN_RANGE 0->1` örneği `[enter, hover]` (ya da `[enter, down]`) üretir; tablo yalnız enter'ı sayıyor, imlecin kalem konumuna gitmesi için hover eklendi (PEN-1).
  6. **Hareket bastırma:** kalem temasında (ve başka bir kaynak sol düğmeyi tutarken) sahip olmayan kaynakların imleç hareketi bastırılır; sol düğmeyi tutmayan parmak hiç imleç oynatmaz (avuç). Basış/bırakış kuralları §7'ye birebir uyar; hareket kuralı §7'de yok (OWN-6, OWN-7).
  7. **Parmak kapısı:** süre kalemin son PEN mesajının host `now` değerinden sayılır (istemci `time_us`'i değil), herhangi bir bayrakla; `< 1 sn` ise kapı kapalı (tam 1 sn'de açık). Watchdog ve release-all kapıyı açmaz (GATE-5/6). Kapı TOUCH'ın tüm yeni basışlarına (sağ/orta dahil) uygulanır.
  8. **DOUBLE_TAP** modu hemen çevirir ama araç değişimi bir sonraki PEN örneğinde (en geç 100 ms) uygulanır; vuruş ortasında çevrilirse vuruş biter (up), devamı hover (ERASER-4). Etkin araçtan farklı bir araçtan gelen `flags=0` örneği de etkin aracı kapatır (araç değişimi kuralı).
  9. **Zorunlu scroll bitişleri** (yeni BEGAN, watchdog, release-all, istemci CANCELLED) `.cancelled`; yalnız istemci ENDED `.ended` üretir.
  10. Onay öncesi mesajları SessionMachine zaten eler, makine tekrar süzmez. NaN/Inf'i codec reddeder, makine ayrıca süzmez.
- **Test edilmeyenler / cihazda doğrulanacaklar:** Yalnızca saf birim/fuzz testleri; CGEvent ve gerçek kalem yok. T-023/T-025'te: (1) gerçek kalemde `[enter, hover]` sırası ve imleç yerleşimi; (2) istemcinin 100 ms canlılık tekrarı ile 500 ms watchdog sınırı (sık watchdog görülüyor mu); (3) avuç/kalem önceliği ve 1 sn kapı süresi elde rahat mı; (4) çift dokunma gerçekten tek DOUBLE_TAP mı ve Krita'da silgi ucu geçişi; (5) arka plana alıp dönünce vuruş ortası örneklerin çizim başlatmadığı; (6) `nextDeadline` ile zamanlayıcının watchdog'u kaçırmaması (T-023 bağlaması).
- **Açık sorular:**
  - Varsayım 1 (işaretçi kaynaklarında bildirilen durumun release-all'da korunması) ve 2 (watchdog kilidi) için PROTOCOL.md'ye tek cümlelik netleştirme eklenmeli mi? Orkestratör karar versin.
  - İstemci (T-024) release-all sonrası her kaynağın bırakışını `buttons=0` mesajıyla bildirmeli; yoksa varsayım 1 yüzünden o kaynağın bir sonraki ilk basışı kaybolur. T-024 kartına not düşülmeli.
  - Klavye (Faz 3) aynı `releaseAll` içine eklenecek; `KEY` şimdilik makinede yok.
