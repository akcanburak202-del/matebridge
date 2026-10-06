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

(ajan doldurur)

## Handoff

## Open questions
