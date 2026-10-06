---
id: T-276
title: Client — yerel imleç (0036): imleç katmanı, şekil önbelleği, zaman aşımı geri dönüşü, panel
<<<<<<< HEAD
status: review
=======
status: todo
>>>>>>> main
phase: 6
owner: android-client-dev
depends_on: [T-274]
decisions: [0036]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/
  - client-android/app/src/main/res/
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - backlog/tasks/T-276-client-local-cursor.md
---

## Amaç

Karar 0036, PROTOCOL (dal `task/T-274-cursor-protocol`). **Bu dalı `task/T-274-cursor-protocol` üzerine kur.**

## Kabul

1. Kodekler (`CURSOR_PREFS`, `CURSOR_SHAPE`, `CURSOR_STATE`), HELLO bit13; bütün yeni fixture'lar `FixtureTest`'te.
2. Katman: video yüzeyinin (SurfaceView) üstünde hafif bir View; video yoluna ve girdi yoluna dokunmaz (dokunmaları geçirir). En yeni `seq`'i çizer, eskiyi yok sayar. Şekil boyutu `width_pt16/16 × (yüzey_px / STREAM_CONFIG.width_pt)`, hotspot aynı ölçekle; `visible = 0` → gizli. Çizim vsync'te (Choreographer), gelen her STATE'te değil; çizim maliyeti ölçülür.
3. Önbellek: ≥ 64 şekil, LRU (kullanım = SHAPE ya da onu anan STATE), bilinmeyen biçimler dahil (yerleşik ok). PNG çözümü arka planda, sınırlı.
4. `CURSOR_PREFS`: Günlük ve Çizim'de ayar "Tablette" ise `1`, Oyun'da ve ayar "Görüntüde" ise `0`; mod/ayar değişince ve oturum başında (kabulden sonra) gönderilir. Zaman aşımı: PREFS(1)'den sonra 1,5 s STATE yoksa (ya da kesilirse) katman gizlenir, PREFS(0) gönderilir; yeniden deneme en erken 10 s sonra (log `cursor_fallback`).
5. Panel: "İmleç: Tablette / Görüntüde", varsayılan Tablette, kalıcı; Oyun modunda not "Oyun modunda görüntüde".
6. Oturum sonu, arka plan, yeniden bağlanma: katman temizlenir, önbellek oturumla birlikte silinir.
7. Log: `cursor_prefs_sent enabled=`, saniyelik sayaçlar (state, shape, çizim ms, STATE yaşı p50/p95 saat farkıyla); konum dökümü yok.
8. `./scripts/check.sh` (host fixture testi T-275 gelene kadar yalnız yeni fixture'lar yüzünden düşebilir — açıkça yaz). Mac'te pencere açma, tablete dokunma.

## Plan

<<<<<<< HEAD
1. Codec (`protocol/`): `MsgType` 0x0B/0x0C/0x0D, `Capabilities.LOCAL_CURSOR` (bit13), mesajlar `CursorPrefs`, `CursorShape`, `CursorState`; `Codec` encode/decode (CURSOR_SHAPE `data_len` 1..61440 ve `16 + data_len` kuralı, bilinmeyen `format` hata değil); `FixtureTest`'e 6 yeni fixture; `CursorCodecTest` (fixture'ın göstermediği kurallar).
2. Saf mantık (`cursor/`, JVM testli): `CursorStateSlot` (u32 seri aritmetikle en yeni `seq`), `ShapeCache` (LRU >= 64), `CursorShapes` (PNG çözümü arka planda, sınırlı kuyruk, IHDR boyut denetimi, bilinmeyen biçim = yerleşik ok), `CursorGeometry` (nokta -> piksel ölçeği, hotspot), `CursorPrefsPolicy` (istek/zaman aşımı/10 s+ yeniden deneme, geri çekilmeli), `CursorStats` (sayaçlar + p50/p95), `CursorLink` (okuyucu iş parçacığı girişi: oturum nesli, STATE/SHAPE yönlendirme).
3. Katman (`cursor/CursorOverlayView`): SurfaceView üstünde dokunmaz View, `postInvalidateOnAnimation(dirty)` ile vsync'te çizim, onDraw süresi ve STATE yaşı ölçülür.
4. Oturum (`session/`): `SessionListener.onCursor(msg, gen)` (ses gibi okuyucudan doğrudan, `acceptedGen` kapısı), `SessionMachine` `initialCursor` + `Event.SetCursor` + `acceptSession`'da `CURSOR_PREFS`, `SessionController.setCursorEnabled`, log `cursor_prefs_sent enabled=`.
5. Ayar/panel: `Settings.cursorLocal()` (varsayılan Tablette, kalıcı, USER_KEYS), `SettingsHost.cursorLocal/setCursorLocal`, `SettingsCatalog` "İmleç: Tablette / Görüntüde" (Oyun'da not), `MainActivity` bağlama (HELLO bit13, mod değişimi, oturum başı/sonu, onStop, saniyelik log, inputTicker'da zaman aşımı).
6. Testler: yukarıdakilerin hepsi için JVM testleri; `./scripts/check.sh`.

## Handoff

- **Commit:** T-276 uygulama commit'i bu dalın tepesinde (`git log -1 task/T-276-client-local-cursor`); önceki commit `45742e56` yalnız kart + plan. Dal `task/T-274-cursor-protocol` üzerine kuruldu.
- **check.sh:** android (JVM testleri), probes, protocol fixtures, crypto vectors, measurement kit **OK**. Tek kırmızı: host `swift test` -> `FixtureTests.everyFixtureFileHasATestCase` (yalnız yeni 6 cursor fixture'ı: `cursor_prefs_on/off`, `cursor_shape`, `cursor_state`, `cursor_state_hidden`, `invalid_cursor_shape_short` host tarafında henüz kapsanmıyor); T-275 gelince kapanır. Başka host hatası yok. Kotlin tarafı 6 fixture'ın hepsini `FixtureTest`'te geçiyor (decode, byte-özdeş encode, bayt bayt ve rastgele parça, invalid reddi).
- **Dokunulan dosyalar** (`client-android/app/src/...`):
  - Protokol: `main/.../protocol/Messages.kt` (MsgType 0x0B-0x0D, `Capabilities.LOCAL_CURSOR` bit13, `CursorPrefs`, `CursorShape`, `CursorState`), `Codec.kt`.
  - Yeni paket `main/.../cursor/`: `CursorStateSlot` (u32 seri aritmetikle en yeni seq), `ShapeCache` (LRU, 64), `CursorShapes` (arka planda PNG çözümü, sınırlı kuyruk 8, IHDR boyut denetimi <= 256 px), `PngInfo`, `CursorGeometry` + `BuiltinArrow`, `CursorPrefsPolicy` (istek, 1,5 s zaman aşımı, geri çekilmeli yeniden deneme), `CursorStats`, `CursorLink` (okuyucu iş parçacığı girişi), `CursorOverlayView` (katman).
  - Oturum: `session/SessionMachine.kt` (`initialCursor`, `Event.SetCursor`, `acceptSession`'da `CURSOR_PREFS`, `deliversCursor`), `SessionController.kt` (`setCursorEnabled`, `listener.onCursor`, okuyucudan doğrudan teslim, log `cursor_prefs_sent enabled=`), `Settings.kt` (`cursorLocal`, USER_KEYS).
  - Panel: `settings/SettingsCatalog.kt` ("İmleç": Tablette / Görüntüde, Oyun'da başlıkta "(Oyun modunda görüntüde)"; Görüntü bölümünde "Boşta karart"ın altı).
  - `MainActivity.kt`: HELLO bit13, katman (pen overlay'in üstünde, istatistik metninin altında), mod/ayar değişiminde `applyCursorWish`, oturum başı/sonu (`render`, `onStop`, `onConnectionGen`, `onSessionEnd`), `inputTicker`'dan zaman aşımı + saniyelik sayaç.
  - Testler: `FixtureTest` (+6 fixture), yeni `CursorCodecTest`, `CursorPrefsMachineTest`, `cursor/*Test` (slot, shapes/LRU/PNG, geometry, policy, stats, link), güncel `SettingsCatalogTest`, `SettingsResetTest` (19 -> 20 anahtar), `SessionSupportTest`.
- **Varsayımlar / tasarım kararları:**
  1. `CURSOR_*` mesajları ses gibi okuyucu iş parçacığından doğrudan `listener.onCursor`'a gider (motor kuyruğuna girmez; yalnız makinenin kabul ettiği, yerel güvenilir nesil). En yeni `seq` kazanır; çizim `postInvalidateOnAnimation(kirli dikdörtgen)` ile vsync'te, her STATE'te değil.
  2. Politika (UI iş parçacığı): istek = ayar "Tablette" ve mod Oyun değil. Makine "wire" değerini hatırlar ve her oturum kabulünde gönderir (`CURSOR_PREFS`, Ping + STREAM_PREFS + AUDIO_PREFS'ten sonra); mod/ayar değişince `Event.SetCursor`. Oyun'a geçerken `setStreamMode` içinde `CURSOR_PREFS(0)` `STREAM_PREFS`'ten **önce** gider (PROTOCOL 0x0D).
  3. Zaman aşımı 1,5 s (PREFS(1) kabulünden / son STATE'ten); düşünce katman gizlenir, PREFS(0) gider, log `W cursor_fallback reason=timeout retry_ms= count=`. Otomatik yeniden deneme en erken 10 s sonra; **sapma (izinli: "en erken")**: STATE görmeden art arda düşüşlerde bekleme 10, 20, 40, 60 s (üst sınır) — PREFS'i yok sayan eski bir host'u her 10 s rahatsız etmesin. Kullanıcının/modun gerçek istek değişimi hemen uygulanır; istek değişmediği sürece (ör. Günlük->Çizim) düşüşün beklemesi kısalmaz.
  4. Şekil önbelleği oturum (kontrol bağlantısı nesli) başına: yeni bağlantı/geçiş (migration) ve oturum sonunda silinir; katman kapalıyken (düşüş, "Görüntüde") **silinmez** ve gelen SHAPE'ler yine saklanır, çünkü host o kimlikleri istemcide sanıyor. STATE katman kapalıyken yok sayılır.
  5. Henüz çözülmemiş şekil: önceki şekil ekranda kalır; bilinmeyen biçim, PNG hatası, > 256 px ya da dolu kuyruk: yerleşik ok. Şekil ölçeği `genişlik_pt16/16 × (video yüzeyi genişliği px / STREAM_CONFIG.width_pt)`, hotspot aynı ölçek, konum `Coords.normalize`'ın tersi (letterbox'a saygılı).
  6. Seq karşılaştırması u32 seri aritmetik (sarma güvenli). `shape_id = 0` yok sayılır (spec hata demiyor).
  7. HELLO bit13 her zaman açık (kapatan geliştirici bayrağı eklenmedi).
  8. Log: `I session cursor_prefs_sent enabled=`, `I render cursor_stats states shapes stale draws draw_ms_avg draw_ms_max age_ms_p50 age_ms_p95 age_n` (saniyelik, boş saniyede yazılmaz; yaş = istemci saati − (host_time_us − PING/PONG ofseti), ofset yokken örneklenmez). Konum, şekil içeriği, tuş yok.
  9. **Codex --high düzeltmeleri (2. commit):** (a) `CursorLink`: nesil/`enabled` denetimi ve durum değişikliği (offer, `lastStateMs`, `reset`, `enable`) tek kilit altında; eski bağlantının duraklamış işleyicisi yeni oturumun slotuna eski yüksek seq'i yazamaz (yeni oturum seq 1'den başlar), `beginSession` işleyen bir kabulü bekler. `lastStateMs` yalnız KABUL edilen (en yeni seq) STATE'te güncellenir; donmuş imleç zaman aşımına düşer. Testler: `CursorLinkTest` (kilit yarışı iki iş parçacığıyla, yalnız kabul edilen STATE zaman aşımını erteler). (b) Sıra (2. tur ile değişti): sabit boşaltma önceliği, 'motor boş imleç slotunu görür, ön alınır, UI SetCursor(false) + Oyun SetPrefs gönderir, motor prefs'i önce alır' araya girmesini kapsamıyordu. Artık ekran modu ve imleç isteği TEK sıralı komut: `EngineMailboxes.mode` (`ModeSlot`), gönderimler CAS ile birleşir (her parçanın en yenisi kazanır, tekrar gönderilmeyen parça kalır), `take()` komutun tamamını tek seferde alır; `SessionMachine.Event.SetMode(cursor, prefs)` önce imleci, sonra `STREAM_PREFS`'i işler. Motor ya hiçbir şey, ya yalnız imleç kısmı (önce gönderilen), ya da ikisini birlikte görür; prefs tek başına imlecin önüne geçemez. Testler `EngineMailboxesTest`: CAS ile okuma ile yayın arasına motorun `take()`'ini sokan deterministik kancalar (uyku yok), iki gönderimin yarışı, parçaların birleşmesi, makinenin `[CursorPrefs(false), StreamPrefs]` sırası. Eski `SetCursor`/`SetPrefs` olayları makinede duruyor (testler kullanıyor); kontrolcü yalnız `SetMode` gönderir. (c) `shape_id = 0` ("host şekli okuyamadı"): STATE kabul edilir, şekil yok sayılır ve katman yerleşik oku çizer (bilinmeyen kimlikle aynı yol); test `CursorLinkTest`.
- **Test EDİLMEDİ (tablet gerekir):** katmanın gerçek görünümü/hizası (`CursorOverlayView.onDraw`, kirli dikdörtgenle artefakt kalıp kalmadığı), `BitmapFactory` ile PNG çözümü, `postInvalidateOnAnimation` gecikmesi, çizim süresi, gerçek host ile uçtan uca (T-275 yok), Oyun geçişi, eski host'a karşı zaman aşımı yolu.

### Tablette kontrol listesi (T-275 host ile birlikte)

1. Günlük, ayar "Tablette": imleç hareketi (trackpad, fare, kalem hover) video imleci olmadan, hotspot ve boyut Mac'tekiyle aynı; `adb logcat -s 'MB/*' | grep -E 'cursor_'` içinde `cursor_prefs_sent enabled=1`, saniyelik `cursor_stats` (states ~ hareket hızı, `draw_ms_avg` < 1, `age_ms_p50/p95` USB'de ~5-10 ms, Wi-Fi ~15-25 ms beklenir; "Görüntüde" ile gerçek gecikme farkını el ile de hisset).
2. Şekiller: metin üstünde I-beam, link üstünde el, pencere kenarında yeniden boyutlandırma okları; şekil değişince titreme/ok'a düşme olmamalı. Yazarken imleç gizlenmeli (visible=0), hareketle dönmeli.
3. Panel: "İmleç" Tablette/Görüntüde anında etkili olmalı (Görüntüde: tablette katman yok, video imleci geri), kalıcı (uygulamayı kapat-aç); Oyun'a geçince başlıkta "(Oyun modunda görüntüde)", Oyun'dan çıkınca Tablette ise geri gelir; Günlük<->Çizim geçişinde kesinti olmamalı.
4. Zaman aşımı: host'ta imleç akışını durdur (ya da eski host sürümü) -> ~1,5 s sonra `W cursor_fallback`, imleç videoda görünür (imleçsiz kalma yok), 10 s+ sonra yeniden dener.
5. Oturum sonu/yeniden bağlanma/arka plana atma: katmanda eski imleç kalmamalı; USB<->Wi-Fi geçişinde (migration) imleç yeniden gelmeli; bir sonraki oturum "Tablette" ile başlamalı. Pencere sürüklerken imleç, pencere videosundan ~40 ms önde olur (karar 0036'da kabul).

## Open questions

- Spec: `CURSOR_PREFS(0)` sonra `(1)` döngüsünde host'un "istemcide var" kümesini sıfırlayıp sıfırlamadığı PROTOCOL.md'de yazmıyor. İstemci güvenli tarafta: katman kapalıyken de SHAPE'leri saklar ve önbelleği yalnız bağlantı/oturum sınırında siler. Host sıfırlıyorsa sorun yok, sıfırlamıyorsa da tutarlı. Yazılması iyi olur.
- Spec: PREFS'i yok sayan eski host'a karşı zaman aşımı sonsuz döngüde kalır; geri çekilmeli (10-60 s) uygulandı (bkz. Handoff 3). İstenmiyorsa `CursorPrefsPolicy` içindeki katlama kaldırılır.
- `CURSOR_SHAPE` PNG sınırı: spec 128 x 128 px diyor, istemci bellek güvenliği için 256 px'e kadar kabul eder (büyüğü ok'a düşer); spec'e yazılabilir.
=======
(ajan doldurur)

## Handoff

## Open questions
>>>>>>> main
