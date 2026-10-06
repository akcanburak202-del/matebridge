---
id: T-275
title: Host — yerel imleç (0036): imleç izleyici, CURSOR_SHAPE/STATE gönderimi, videoda imleci kapatma
status: review
phase: 6
owner: mac-host-dev
depends_on: [T-274]
decisions: [0036]
files:
  - host-mac/Sources/MateBridgeCore/
  - host-mac/Sources/MateBridgeHost/
  - host-mac/Tests/MateBridgeCoreTests/
  - docs/LOGGING.md
  - backlog/tasks/T-275-host-local-cursor.md
---

## Amaç

Karar 0036, PROTOCOL (dal `task/T-274-cursor-protocol`): HELLO bit13, 0x0B/0x0C/0x0D, §5 imleç kuyruğu. **Bu dalı `task/T-274-cursor-protocol` üzerine kur.** Bilgi kaynağı T-271 probu (`probes/cursor-probe`, NOTES 2026-10-06 ~13:50): `NSCursor.currentSystem` (şekil, hotspot, temsiller), `CGCursorIsVisible` (dlsym; T-272'deki `SystemCursorVisibility` yeniden kullanılır), konum `CGEvent(source:nil).location`.

## Kabul

1. Core: kodekler (`CURSOR_PREFS`, `CURSOR_SHAPE`, `CURSOR_STATE`), bit13; bütün yeni fixture'lar `FixtureTests`'te. Saf `CursorStreamPlanner`: PREFS → açma/kapama sırası (önce SHAPE + STATE, sonra video imleci kapat; kapatırken önce video imleci aç), değişiklikte STATE (en sık ~8 ms, en yenisi kazanır), en az 500 ms'de bir STATE, şekil önbelleği 32 LRU (kullanım = SHAPE ya da STATE referansı), oturum sonunda temizlik. Normalize konum: §1 girdi eşlemesinin tersi (sanal ekran sınırları, kenara sıkıştırma; oyun ekranı 1x dahil). Testli.
2. Host: imleç izleyici yalnız PREFS(1) iken çalışır (~120 Hz yoklama + her `POINTER_*`/kalem/dokunma enjeksiyonundan hemen sonra bir örnek). Şekil özeti (görüntü baytları + hotspot) değişince en uygun temsil seçilir, ≤ 128×128 px'e küçültülür, PNG'ye (ImageIO, yeni bağımlılık yok) ≤ 61 440 bayt kodlanır. Ana iş parçacığı gerekiyorsa ona göre; maliyet ölçülüp log'a.
3. Video: `ScreenCapture` `showsCursor`'ı akışı kurmadan değiştirir (`SCStream.updateConfiguration`); başarısızsa video imleci kalır ve `CURSOR_*` gönderilmez (protokoldeki "uygulayamazsa" kuralı). Oturum sonu/devralma/uyku → video imleci geri açık.
4. Gönderim kontrol bağlantısında H→C; girdi yönünü (C→H) etkilemez. Tıkanmada STATE beklemez (tek bekleyen, en yenisi).
5. Log: `ev=cursor_prefs enabled=`, `ev=cursor_video shows=0|1`, saniyelik sayaçlar (state, shape, örnek maliyeti p50/p95 µs); şekil görüntüsü/konum dökümü yok.
6. Mac'te pencere açma; testte imleci hareket ettirme, tıklama, enjeksiyon yapma; çalışan host'a dokunma. `./scripts/check.sh` (istemci fixture testi T-276 gelene kadar yalnız yeni fixture'lar yüzünden düşebilir — açıkça yaz).

## Plan

1. Core (saf, testli): `CursorPrefs`/`CursorShape`/`CursorState` kodekleri + `Message`/`MessageType` 0x0B-0x0D + `Capabilities.localCursor` (bit13); `SessionMachine`: `CURSOR_PREFS` etkin oturumdan `.deliver`, `CURSOR_SHAPE/STATE` yanlış yön (yok sayılır). `FixtureTests`'e 6 yeni fixture.
2. Core: `CursorStreamPlanner` (PREFS sırası: önce SHAPE+STATE, sonra video imleci kapat; kapatırken önce video imleci aç; değişiklikte ~8 ms, en az 500 ms), `CursorShapeCache` (32 LRU), `CursorOutbox` (tek bekleyen birim, gönderim tamamlanınca bir sonraki), `CursorShapeLayout` (temsil seçimi, ≤128 px, pt16, shape_id), `DisplayGeometry.normalizedPosition` (girdi eşlemesinin tersi), `CursorStats` (saniyelik sayaç).
3. Host: `VideoCursorSwitch` (istenen durum + canlı `ScreenCapture`'a `updateConfiguration`; yeni yakalama istenen durumla başlar), `CursorTracker` (~120 Hz yoklama + enjeksiyon sonrası örnek; `NSCursor.currentSystem` -> PNG ImageIO), `CursorService` (planner + outbox + önbellek, `SessionServer` içinden bağlı: `main.swift` `files:` dışında olduğu için bağlama `SessionServer` içinde yapılır).
4. Log (`component=cursor`) + `docs/LOGGING.md`. check.sh.

## Handoff

- **Commit:** `a28102b4` (kod; plan `0e1e0dc1`), dal `task/T-275-host-local-cursor`, `task/T-274-cursor-protocol` üzerine. Handoff ayrı commit.
- **check.sh:** host-mac `swift build` + `swift test` (tüm yeni testler dahil), tüm probe'lar, protokol fixture/crypto, ölçüm kiti: **OK**. Tek kırmızı: `gradle (client-android)` `FixtureTest.everyFixtureFileHasATestCase` (6 yeni imleç fixture'ı için istemci test durumu yok: `cursor_prefs_on/off`, `cursor_shape`, `cursor_state`, `cursor_state_hidden`, `invalid_cursor_shape_short`); beklenen, T-276'da kapanır. Başka Android hatası yok.
- **Dosyalar:**
  - Core: `Protocol/CursorMessages.swift` (kodekler), `Message.swift`, `ProtocolConstants.swift`, `Messages.swift` (bit13 `localCursor`), `Session/SessionMachine.swift` (`CURSOR_PREFS` etkin oturumdan `deliver`, `SHAPE/STATE` yok sayılır), `Input/InputStateMachine.swift` (yalnız kapsayıcı case); `Cursor/`: `CursorStreamPlanner`, `CursorShapeCache` (+ `CursorOutbox`, `CursorShapeStore`), `CursorShapeLayout` (+ `DisplayGeometry.normalizedPosition`), `CursorStats`.
  - Host: `Cursor/CursorSampler.swift` (NSCursor.currentSystem + CGEvent konum + `SystemCursorVisibility`, ImageIO PNG), `Cursor/CursorService.swift` (planner + outbox + önbellek + yoklama zamanlayıcısı), `Video/VideoCursorSwitch.swift`, `Video/ScreenCapture.swift` (`showsCursor` başlangıçta istenen durumla, `setShowsCursor` = `updateConfiguration`), `Session/SessionServer.swift` (kancalar + `sendCursor`).
  - Testler: `Cursor/CursorCodecTests`, `Cursor/CursorPlannerTests` (planner, önbellek, outbox, mağaza, yerleşim, geometri, sayaç), `FixtureTests` (6 yeni fixture), `SessionMachineTests` (+2). `docs/LOGGING.md` (`component=cursor`).
- **Tasarım ve varsayımlar:**
  - **`main.swift` değişmedi** (`files:` dışı). Bağlama `SessionServer` içinde: `CursorService` onun içinde kuruluyor; oturum başı/sonu ve `CURSOR_PREFS` mevcut `.sessionStarted/.sessionEnded/.deliver` eylemlerinden, enjeksiyon örneği `handlers.deliver` (enjeksiyon senkron) döndükten sonra `pen/pointerRel/pointerAbs/scroll/pinch/penGesture` için tetikleniyor. Video imleci için işlem genelinde `VideoCursorSwitch.shared` (istenen durum + canlı `ScreenCapture`); yeni yakalama (yeniden yapılandırma, ekran uyanması) istenen durumla başlar.
  - Örnekleme kendi kuyruğunda (`dev.matebridge.cursor`), ana iş parçacığında değil: `NSCursor.currentSystem` arka plan kuyruğundan çalıştı (ajan ortamında denendi: ilk çağrı ~16 ms, sonra ~50 µs). Yoklama 120 Hz `.strict` zamanlayıcı; enjeksiyondan hemen sonra bir örnek + 1,5 ms sonra bir izleme örneği (WindowServer konumu bir an sonra uygular diye); örnekler birleşir (en çok bir bekleyen).
  - Şekil: `chooseRepresentation` = 2 piksel/nokta'ya yetecek en küçük temsil (yoksa en büyük); sRGB RGBA'ya çizilir, karması id'yi (piksel karması + pt boyutu + hotspot) verir; yeni id ise ≤128 px'e küçültülür, ImageIO PNG (RGBA 8 bit, düz alfa doğrulandı), > 61 440 bayt ise 3/4 ölçekle yinelenir. Saniyede en çok 20 yeni şekil (kararsız görüntü şekil yağmuruna yol açmasın); aşılırsa son şekil kalır, `cursor_shape_flood` W.
  - Önbellek 32 LRU host tarafında ve **yalnız yazım anında** güncellenir (`CursorOutbox` ile: tek bekleyen birim, öncekinin yazımı bitmeden yenisi yazılmaz, değişen birimin şekli "var" sayılmaz). `PREFS(0)` ve oturum sonunda temizlenir (tablet kapatınca görüntüleri bırakabilir; bir sonraki açılışta şekil yeniden gider). Mağazada (48) bulunmayan şekil için `shape_id = 0` (yerleşik ok) gönderilir ve önbellekte "var" sayılmaz.
  - Başarısız `updateConfiguration`: planner isteği unutur (`wanted=false`), `CURSOR_*` kesilir, video imleci kalır; tablet 1,5 s sonra kendi katmanını gizleyip 10 s sonra yeniden dener. Kapatırken video imleci başarısız dönse bile akış durur.
  - İmleç sanal ekran dışında (başka ekranda) ise konum kenara sıkıştırılır (kart); sanal ekran/geometri yoksa o örnek gönderilmez (tablet zaman aşımına düşer). Gizliyken şekil yeniden okunmaz, son şekil + `visible=0` gider.
  - `STATE` her gönderimde `seq` yazım anında atanır (oturumda 1'den artar, `PREFS(0)->(1)` arasında sürer).
- **Mac'te doğrulananlar (yalnız okuma; imleç oynatılmadı, tıklama/enjeksiyon/pencere yok):** geçici (commit edilmeyen) bir test paketiyle gerçek `CursorSampler` + `CursorService` (sahte yazıcıyla): şekil PNG'si üretiliyor (örnek: 24x18 pt, 48x36 px, 1346 B, RGBA), kararlı id, ilk toplu `SHAPE+STATE`, `seq` 1,2,3 ve imleç duruyorken ~500 ms'de bir `STATE` (keep-alive), `PREFS(0)` sonrası gönderim yok, yeniden açınca şekil yine gelir, yazıcı tıkanınca kuyruk büyümüyor (tek bekleyen), `HELLO` bit13 yoksa `PREFS` yok sayılıyor. Örnek maliyeti (debug derleme, sıcak): p50 ~100 µs, p95 ~130 µs.
- **Test EDİLMEDİ (gerçek donanım / çalışan host gerekir):**
  1. `SCStream.updateConfiguration` ile `showsCursor` değişiminin akışı bozmadan ve kare kesintisi/keyframe ihtiyacı olmadan çalıştığı (HDR10, 4:4:4 paketli, oyun ekranı 1x dahil). Başarısızlık yolu (W `ev=cursor_video ok=0`) denenmedi.
  2. Gerçek enjeksiyonlarda imleç konumunun `CGEvent(source:nil)` ile ne kadar çabuk güncellendiği (ilk örnek + 1,5 ms izleme örneği yeterli mi, `host_time_us` farkı).
  3. Gerçek imleç çeşitliliği (el, yeniden boyutlandırma, I-beam, uygulamanın özel imleci, erişilebilirlik büyütmesi 128 px üstü), `cursor_stats` `shapes_built` ve `sample_us_p50/p95` değerleri release derlemede.
  4. 120 Hz yoklamanın boşta CPU maliyeti (tahmin %0,5-1 çekirdek; `sample_us_*` ve Activity Monitor ile bakılmalı).
  5. Büyük bir `SHAPE` yazılırken ses: `kernelAudioBacklog` kapısı kısa süre ses paketi düşürebilir (yalnız yeni şekilde, genelde 1-3 KB; en kötü 60 KB).
  6. Oturum sonu / devralma / uyku sırasında video imlecinin geri gelmesi (`VideoCursorSwitch.reset` + `ScreenCapture.stop`).
- **Cihazda kontrol (T-276 ile birlikte):** (1) tablet panelinden "İmleç: Tablette" açınca `host.log`'da `cursor ev=cursor_prefs enabled=1`, `cursor_video shows=0 ok=1`, saniyede bir `cursor_stats` (`states` hareketle artar, boşta ~2/s); (2) video akışında Mac imleci kaybolur, tablet katmanı gelir; (3) kapatınca `shows=1` ve imleç videoda geri; (4) oturumu aniden kesince (kablo çek / Wi-Fi) imleç sonraki oturumda videoda; (5) Oyun modu: `PREFS(0)`, video imleci kalır.

## Open questions

- **`main.swift` bağlaması:** kart `host-mac/Sources/MateBridgeApp/`'i listelemiyor; bağlama bu yüzden `SessionServer` içinde ve `VideoCursorSwitch.shared` tekili üzerinden yapıldı (`StreamCoordinator`/`main.swift` değişmedi). İstenirse sonraki bir kartta açık bağımlılık enjeksiyonuna çevrilebilir.
- **PROTOCOL.md sorusu (orkestratör):** §0x0B "önce SHAPE+STATE sonra video imleci" sırasını host yalnız *kuyruğa alma* sırası olarak uygular: ilk birim outbox'a girer girmez `setVideoCursor(false)` istenir (yazımın bitmesi beklenmez; kontrol/video zaten ayrı bağlantı, "en iyi çaba" notuyla uyumlu). Yazım tamamlanmasını beklemek istenirse planner'a bir adım eklenir.
- **PROTOCOL.md sorusu:** `CURSOR_STATE.shape_id = 0` host tarafından "yerleşik ok" için kullanılıyor (mağazadan düşen şekil, okunamayan ilk şekil). §0x0D "istemcide yoksa yerleşik ok" cümlesiyle uyumlu ama `0`'ın bu anlamı açıkça yazılı değil; T-276 `0`'ı da "bilinmeyen id" gibi ele almalı.
- **PROTOCOL.md sorusu:** host `PREFS(0)`'da kendi "istemcide var" önbelleğini boşaltıyor (istemcinin ≥64 şekil tutma kuralına güvenmiyor); bir sonraki `PREFS(1)`'de şekiller yeniden gider. İstemci kapatınca şekil önbelleğini tutarsa bu yalnız fazladan birkaç KB'tır.
- **Ayrıca (kapsam dışı, not):** `InputController.deliver` yine `queue.sync` ile oturum kuyruğunu bloke ediyor; imleç örnekleri bu yüzden enjeksiyon bittikten *sonra* (oturum kuyruğunda) tetikleniyor, girdiyi ek olarak geciktirmiyor ama enjeksiyon yavaşsa imleç de gecikir.

## Codex --high düzeltmeleri (2 x P2, host)

- **P2-1 (eski oturumun gizlemesi sonraki oturumda imleci gizliyor):** `VideoCursorSwitch.set(shows:generation:)` artık oturum kuşağını ister (`CursorService` oturum başında `video.generation`'ı okur); `reset()` (oturum sonu) yeni kuşak başlatır, eski kuşaktan gelen istek anahtarlanırken ya da uygulanırken reddedilir. Sıralama mantığı saf Core'da: `VideoCursorWish` (bilet = epoch + kuşak; `begin` yalnız en yeni ve canlı kuşaktaki bileti uygular). Testler: `CURWISH3` (reset'ten sonra gelen eski gizleme reddedilir), `CURWISH4` (reset'ten önce biletlenmiş gizleme uygulanamaz, sonraki oturum yeniden gizleyebilir), `CURWISH5`.
- **P2-2 (başarısız gösterme kalıcı imleçsiz yakalama bırakıyor):** istenen durum bir başarısızlıkta hep "imleç videoda"ya döner (eski kod gerçek değere, yani gizliye, çekiyordu); başarısız **gösterme** sınırlı geri çekilmeyle (0,25 s ... 8 s) kendiliğinden yeniden denenir, daha yeni bir istek/oturum sonu denemeyi iptal eder; yeniden başlayan/eklenen her yakalama istenen duruma uyar (`attach` + `ScreenCapture.start`). Başarısızlık `W cursor ev=cursor_video_failed ... attempt= retry_ms=` ile loglanır (LOGGING.md güncel). Planner `.applyingShow` başarısızlığında akışı yine durdurur (tablet katmanı zaten kapalı); yeniden deneme planner'da değil anahtarda yaşar, böylece oturum sonu `reset()` yolu da kapsanır. Testler: `CURWISH6-9`, `CURWISH11` (geri çekilme sınırlı).
- Test EDİLMEDİ: gerçek `updateConfiguration` başarısızlığı ve yeniden deneme (cihaz gerekir).
