---
id: T-022
title: Mac girdi durum makinesi — kalem, işaretçi, dokunma, release-all (saf, testli)
status: done
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

**Dosyalar** (`host-mac/Sources/MateBridgeCore/Input/`): `InjectAction.swift` (çıktı türleri), `InputStateMachine.swift` (durum + genel API: `handle(_:now:)`, `tick(now:)`, `releaseAll(_:)`), `InputStateMachine+Pen.swift`, `+Pointer.swift`, `+Scroll.swift`. Testler `host-mac/Tests/MateBridgeCoreTests/Input/`.

**Çıktı sözleşmesi (T-023 tüketir):** `penProximity(tool, entering)`, `penHover/penDown/penDrag/penUp(tool, PenPoint)`; `mouseMove(motion, dragging)` (imleci taşır, önce), `mouseButton(button, down)` (imlecin o anki yerinde), `scroll(phase, dx, dy)`, `scrollWheel(dx, dy)`. `PenPoint` = normalize x/y, basınç u16, ham i16 eğim. Bir mesajdaki hareket her zaman düğme geçişlerinden önce gelir.

**Durum:** kalem (etkin araç, temas, son nokta, araç başına kilit), sol düğme sahibi (`pen/rel/mouse/touch`), kaynak başına bildirilen düğmeler (`held`, release-all'da SİLİNMEZ = işaretçi kilidi) ve Mac'e katkı veren sağ/orta/geri/ileri (`contributing`, OR), açık scroll, silgi modu, son kalem örneği zamanı (parmak kapısı + watchdog), son scroll zamanı.

**Kurallar → test adı eşlemesi** (test adları kural kimliğiyle başlar; Handoff'ta tablo): PEN-1..PEN-10 (§4 tablosu satırları + STROKE_START + CONTACT/IN_RANGE=0), LATCH-*, WD-PEN, WD-SCROLL, OWN-* (§7 sahiplik), OR-*, GATE-* (parmak kapısı), REL-* (release-all her tetikleyici + idempotans), ERASER-* (karar 0006), SCROLL-*, WELL-* (iyi niyetli istemci simülasyonu), FUZZ-* (seed'li SplitMix64; gölge Mac modeli: "her down'un up'ı var", çift down/up yok, release-all sonrası hiçbir şey basılı değil, makine durumu = modelin durumu).

**Güvenli okuma seçimleri** (PROTOCOL belirsiz olan yerler, Handoff'ta işaretlenecek): (1) release-all sonrası işaretçi kaynaklarının bildirilen düğme durumu korunur, yani bayat `LEFT` mesajı yeni basış sayılmaz; (2) kalem temasında sahip olmayan kaynakların imleç hareketi bastırılır; (3) araç değişiminde temas sürüyorsa yeni araç için kilit kurulur (vuruş ortası yeni vuruş olmaz); (4) temas sürerken gelen ikinci `STROKE_START` = up + down; (5) DOUBLE_TAP silgi modunu çevirir, araç değişimi bir sonraki kalem örneğinde uygulanır.

**İnceleme turu (orkestratör, PROTOCOL b152c0f):** watchdog'lar her mesajdan önce uygulanır ve saat geri giderse yeniden bağlanır; zorla scroll bitişi ayrı `forcedEnd` fazı; taze makine kilitli başlar; işaretçi sahibi varken kalem hover'ı susar; yeni testler (LATCH-0/9/10, OWN-9/10, WD-4..12, FUZZ-5..7, WELL-1). Ayrıntı Handoff'ta.

Sıra: önce bu plan commit'i, sonra kod + testler, `check.sh`, Handoff.

## Handoff

- **Commit:** kod başı `74b2e35` (dal `task/T-022-host-input-state`; ilk tur `d5cb30d`/`bb527ce`, inceleme turu `47f1060`/`082e89b`, `nextDeadline` düzeltmesi `74b2e35`). Bunun üstündeki commit'ler yalnızca bu kartı günceller. `./scripts/check.sh`: ALL OK (Core 173 test).
- **Dokunulan dosyalar:** `host-mac/Sources/MateBridgeCore/Input/{InjectAction,InputStateMachine,InputStateMachine+Pen,InputStateMachine+Pointer,InputStateMachine+Scroll}.swift`; `host-mac/Tests/MateBridgeCoreTests/Input/{InputTestSupport,PenStateTests,PointerOwnershipTests,SafetyTests,InputFuzzTests,WellFormedClientTests}.swift`; bu kart. Başka dosyaya dokunulmadı; PROTOCOL.md ve fixture'lara dokunulmadı (yalnızca orkestratörün b152c0f netleştirmeleri okundu).
- **İnceleme turu (7 düzeltme + Codex düzeltmesi):**
  1. `handle(_:now:)` her mesajdan önce süresi dolmuş watchdog'ları uygular (`tick` ile aynı iş) ve o eylemleri mesajınkilerden önce döndürür (WD-8/9/10, FUZZ-6: `tick`+`handle` == `handle`).
  2. Saat geri giderse pen/scroll watchdog zaman damgası `now`'a yeniden bağlanır; en kötü 500 ms geç, asla kapalı değil (WD-5/6). Parmak kapısı değişmedi: geri giden saat kapıyı açık tutar (WD-7). Kalemin watchdog damgası (`penWatchdogAnchor`) kapı damgasından (`lastPenSampleAt`) ayrıldı ki kapı yeniden bağlanmasın.
  3. `InjectScrollPhase.forcedEnd` eklendi: yeni BEGAN, watchdog, release-all -> `.forcedEnd` (Mac'e ENDED, atalet yok, süren ataleti durdur); istemci `CANCELLED` -> `.cancelled`; istemci `ENDED` -> `.ended`.
  4. Taze makine iki kalem aracı için de kilitli başlar (LATCH-0, FUZZ-7).
  5. Bir işaretçi kaynağı sol düğmeyi tutarken kalem hover hareketi Mac'e gitmez (proximity enter/leave gider, kalem teması hâlâ düğmeyi alır): on-behalf up sahibin son konumuna düşer (OWN-9/9b).
  6. Yeni testler: LATCH-9 (silgi aracı, 12 neden), LATCH-10, OWN-10 (PEN-5 sonrası işaretçi basışı), FUZZ-1..4 artık sıfır/geri saat adımlı, FUZZ-5 (`tick` tam `nextDeadline`'da), FUZZ-6, FUZZ-7 (bağımsız kilit oracle'ı), WELL-1 (iyi niyetli istemci, 3 mod x 600 seed).
  7. Codex turu: `nextDeadline(now:)` artık `mutating`; geri giden saati `tick`/`handle` ile aynı tek yardımcıyla (`reanchorWatchdogs`) yeniden bağlar. Böylece geri saati ilk gören çağrı `nextDeadline` olsa bile `tick` döndürdüğü anda çalışır ve gecikme en çok bir periyottur (WD-11 kalem, WD-12 scroll, FUZZ-5 geri saatli sonda).
  8. Kart: Plan'daki `releaseAll(_:now:)` -> `releaseAll(_:)`; tablo, varsayımlar ve açık sorular güncellendi.
- **T-023 için API özeti:**
  - Oturum başına bir `InputStateMachine` (değer tipi, kilitsiz; tek kuyruktan kullanılır; durum oturumlar arası taşınmaz). `handle(_ message, now:)` (watchdog eylemleri + mesaj eylemleri; KEY ve diğerleri kendi eylemi üretmez), `tick(now:)`, `releaseAll(_ cause: ReleaseCause)` (`SessionAction.releaseInput`'un nedeni doğrudan geçer), `nextDeadline(now:)` (**mutating**: bir sonraki watchdog anı; geri giden saati `tick`/`handle` gibi önce `now`'a yeniden bağlar, bu yüzden o anda `tick` her zaman çalışır. **API değişikliği:** ilk turdaki `nextDeadline` özelliği `nextDeadline(now:)` oldu ve `var` makine ister). `now` = `HostClock.nowUs()`, mesajın ALINDIĞI an. `handle(.releaseAll/.bye)` da release-all yapar.
  - `InjectAction`: `penProximity(tool, entering)`, `penHover/penDown/penDrag/penUp(tool, PenPoint)`, `mouseMove(MouseMotion, dragging: MouseButton?)`, `mouseButton(MouseButton, down:)`, `scroll(InjectScrollPhase, dx, dy)`, `scrollWheel(dx, dy)`. Liste sırayla uygulanır.
  - Enjektör kuralları: `mouseButton` imlecin O ANKİ konumunda uygulanır (enjektörün son konumu tutması gerekir). `mouseMove.dragging` ilgili `*MouseDragged` tipini seçer (nil = `mouseMoved`). `penUp` basıncı 0'dır. Scroll: `.ended` atalete izin verir, `.cancelled` iptal, `.forcedEnd` Mac'e ENDED olarak gider, atalet üretilmez ve süren atalet durdurulur. Çift tıklama `clickState` enjektörde.
- **Kural -> test eşlemesi** (test adları kimlikle başlar, `swift test` çıktısında görünür):

  | Kural | Testler |
  |---|---|
  | §4 enter / down / drag / up / hover / up+leave sırası | PEN-1..7, PEN-12 |
  | §4 araç değişimi (up + leave + enter; vuruş ortasında yeni araç kilitli) | PEN-8a/b/c, ERASER-3/4 |
  | §4 `CONTACT=1 IN_RANGE=0` -> `flags=0`; `IN_RANGE=0` her araçta etkin aracı kapatır | PEN-9a/b/c, LATCH-6 |
  | §4 `STROKE_START`; aynı örnekte enter+down; temas sürerken `STROKE_START` = up+down | PEN-3, PEN-10, LATCH-3 |
  | §4 kilit (oturum başı + her release-all, araç başına; watchdog kilit kurmaz) | LATCH-0..10, REL-7, FUZZ-3, FUZZ-7 |
  | §7 kalem watchdog 500 ms, saat geri giderse yeniden bağlama | WD-PEN-1..6, WD-4/5, WD-11, FUZZ-5 (geri saatli sonda dahil) |
  | §7 scroll watchdog 500 ms, zorla bitirme | WD-SCROLL-1/2, WD-3, WD-6, WD-12 |
  | §7 mesajdan önce süresi dolmuş watchdog | WD-8/9/10, FUZZ-6 |
  | §7 tek sol düğme sahibi, sahip olmayanın basış/bırakışı etkisiz | OWN-1, OWN-4, OWN-5 |
  | §7 kalem önceliği (önce sahip adına up, sonra kalem down; yeniden basmak gerekir) | OWN-2, OWN-2b, OWN-9 |
  | §7 kalem temasında diğer sol basışlar yok sayılır | OWN-3, OWN-3b, OWN-6, OWN-10 |
  | §7 imleç hareketi: sahip varken diğerleri (kalem hover dahil) susar | OWN-6, OWN-7, OWN-9, OWN-9b |
  | §7 diğer düğmeler OR | OR-1..8 |
  | §7 + karar 0006 parmak kapısı (IN_RANGE + 1 sn; sahibin bırakışı hep işlenir; geri saat kapıyı açmaz) | GATE-1..8, OR-6/7, WD-7 |
  | §7 release-all (12 `ReleaseCause`, mesaj, BYE), işaretçi kilidi, idempotans, sıra | REL-1..10, LATCH-5 |
  | Karar 0006 çift dokunma silgi modu; release-all'da kalem moduna dönüş | ERASER-1..7, LATCH-10 |
  | §4 SCROLL host kuralları (ENDED/CANCELLED/zorla bitirme ayrımı) | SCROLL-1..5, REL-8, WD-SCROLL-1 |
  | "Hiçbir basılı durum kalmadı", "her down'un up'ı var", sıfır/geri saat | FUZZ-1, FUZZ-2, FUZZ-3 (bayat tekrar), FUZZ-4 (determinizm) |
  | İyi niyetli istemci: her şeyi bırakır, host release-all'dan habersiz, son release-all yok -> Mac boşta; meşru basış/vuruş yutulmaz | WELL-1 (host / istemci / ikisi release eder) |

  Testlerin hata yakaladığı elle doğrulandı, üç turda 26 mutasyonla (ör. kilit yok, taze makine kilitsiz, sahip olmayan bırakır, release-all bildirilen düğmeleri siler, kalem önceliği up'ı yok, kapı yalnız TOUCH'a değil hepsine, kapıdayken sahibin bırakışı yok sayılır, `handle` watchdog uygulamaz, geri saatte yeniden bağlama yok (çöker), `nextDeadline` geri saati yeniden bağlamaz (WD-11/12, FUZZ-5 kırmızı), zorla bitirme `.cancelled`/`.ended`, hover bastırma yok, STROKE_START kilidi açmaz, watchdog sahibi bırakmaz). Her biri en az 1 testte kırmızı verdi; sonra geri alındı.
- **Varsayımlar.** Kesinleşenler (orkestratör, PROTOCOL b152c0f) ve bu turdakiler ayrı:
  - *Kesinleşti:* (a) işaretçi kaynaklarının bildirdiği düğme durumu release-all'da silinmez (§7 "işaretçi kilidi"); (b) watchdog kilit kurmaz (§4/§7); (c) vuruş ortasında araç değişimi -> yeni araç kilitli (§4); (d) temas sürerken `STROKE_START` = up+down (§4 tablo); (e) `IN_RANGE=0` örneği hangi `tool` ile gelirse gelsin etkin aracı kapatır (§4); (f) imleç hareketi bastırma, kalem hover dahil (§7); (g) zorla scroll bitişi ENDED, ataletsiz (§4 SCROLL); (h) DOUBLE_TAP silgi modu, araç değişimi sonraki PEN örneğinde (§4/0x15); (i) süre host'un tek saatiyle ve mesajın alındığı anla ölçülür, saat geri gidince yeniden bağlanır (§7).
  - *Hâlâ benim seçimim (PROTOCOL sessiz):*
    1. Enter örneği konumu da bildirir: `IN_RANGE 0->1` örneği `[enter, hover]` (ya da `[enter, down]`); bir işaretçi sol düğmeyi tutuyorsa yalnız `[enter]` (hover bastırılır). Tablo yalnız enter'ı sayıyor.
    2. Parmak kapısı sınırı: `< 1 sn` kapalı, tam 1 sn'de açık; kapı TOUCH'ın tüm yeni basışlarına (sağ/orta dahil) uygulanır; watchdog kapanışı ve release-all kapıyı açmaz (kapı son PEN mesajından sayılır).
    3. `handle` watchdog'ları kendisine verilen HER mesaj türünde uygular (STATS/PING dahil), "her girdi mesajı"nın üst kümesi; sonuç zamanlayıcıdan bağımsız kalır (FUZZ-6).
    4. `nextDeadline` `now` parametresi aldı ve `mutating` (saat geri gidince zamanlayıcı doğru uyansın diye; çağıran makineyi `var` tutmalı).
    5. Kapıda olmayan (basışı kabul edilmemiş) parmak imleci taşımaz; sol düğmeyi hiç tutmayan TOUCH mesajı da imleç oynatmaz.
    6. NaN/Inf'i codec reddeder, makine ayrıca süzmez; onay öncesi mesajları SessionMachine eler.
- **Test edilmeyenler / cihazda doğrulanacaklar:** Yalnızca saf birim/fuzz testleri; CGEvent ve gerçek kalem yok. T-023/T-025'te: (1) gerçek kalemde `[enter, hover]` sırası ve imleç yerleşimi; (2) istemcinin 100 ms canlılık tekrarı ile 500 ms watchdog sınırı (sık watchdog görülüyor mu); (3) avuç/kalem önceliği ve 1 sn kapı süresi elde rahat mı; (4) çift dokunma gerçekten tek DOUBLE_TAP mı ve Krita'da silgi ucu geçişi; (5) arka plana alıp dönünce vuruş ortası örneklerin çizim başlatmadığı; (6) `nextDeadline(now:)` ile zamanlayıcının watchdog'u kaçırmaması (T-023 bağlaması); (7) `.forcedEnd` sonrası ataletin gerçekten durması (Faz 3).
- **Açık sorular:**
  - İşaretçi düğmeleri için watchdog yok: girdi yolu takılan ama kalp atışı süren bir istemci, bağlantı kopana kadar bir düğmeyi basılı tutar (sol sahip ya da sağ/orta OR). Orkestratör Faz 3'e erteledi; bu kartta uygulanmadı.
  - T-024 kartı PROTOCOL §7'deki yeni istemci yükümlülüğünü karşılamalı (`RELEASE_ALL` öncesi basılı her işaretçi kaynağı için `buttons=0`; sonrasında yalnızca yeni basış olayında bildir). Aksi halde işaretçi kilidi yüzünden o kaynağın sonraki ilk basışı yutulur. Orkestratörün kartında.
  - Klavye (Faz 3) aynı `releaseAll` içine eklenecek; `KEY` şimdilik makinede yok.
