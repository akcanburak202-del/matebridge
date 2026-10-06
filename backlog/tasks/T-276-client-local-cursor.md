---
id: T-276
title: Client — yerel imleç (0036): imleç katmanı, şekil önbelleği, zaman aşımı geri dönüşü, panel
status: todo
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

1. Codec (`protocol/`): `MsgType` 0x0B/0x0C/0x0D, `Capabilities.LOCAL_CURSOR` (bit13), mesajlar `CursorPrefs`, `CursorShape`, `CursorState`; `Codec` encode/decode (CURSOR_SHAPE `data_len` 1..61440 ve `16 + data_len` kuralı, bilinmeyen `format` hata değil); `FixtureTest`'e 6 yeni fixture; `CursorCodecTest` (fixture'ın göstermediği kurallar).
2. Saf mantık (`cursor/`, JVM testli): `CursorStateSlot` (u32 seri aritmetikle en yeni `seq`), `ShapeCache` (LRU >= 64), `CursorShapes` (PNG çözümü arka planda, sınırlı kuyruk, IHDR boyut denetimi, bilinmeyen biçim = yerleşik ok), `CursorGeometry` (nokta -> piksel ölçeği, hotspot), `CursorPrefsPolicy` (istek/zaman aşımı/10 s+ yeniden deneme, geri çekilmeli), `CursorStats` (sayaçlar + p50/p95), `CursorLink` (okuyucu iş parçacığı girişi: oturum nesli, STATE/SHAPE yönlendirme).
3. Katman (`cursor/CursorOverlayView`): SurfaceView üstünde dokunmaz View, `postInvalidateOnAnimation(dirty)` ile vsync'te çizim, onDraw süresi ve STATE yaşı ölçülür.
4. Oturum (`session/`): `SessionListener.onCursor(msg, gen)` (ses gibi okuyucudan doğrudan, `acceptedGen` kapısı), `SessionMachine` `initialCursor` + `Event.SetCursor` + `acceptSession`'da `CURSOR_PREFS`, `SessionController.setCursorEnabled`, log `cursor_prefs_sent enabled=`.
5. Ayar/panel: `Settings.cursorLocal()` (varsayılan Tablette, kalıcı, USER_KEYS), `SettingsHost.cursorLocal/setCursorLocal`, `SettingsCatalog` "İmleç: Tablette / Görüntüde" (Oyun'da not), `MainActivity` bağlama (HELLO bit13, mod değişimi, oturum başı/sonu, onStop, saniyelik log, inputTicker'da zaman aşımı).
6. Testler: yukarıdakilerin hepsi için JVM testleri; `./scripts/check.sh`.

## Handoff

## Open questions
