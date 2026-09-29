---
id: T-024
title: Tablet kalem ve dokunma yakalama — PEN toplu örnekler, POINTER_ABS, avuç reddi, RELEASE_ALL
status: todo
phase: 2
owner: android-client-dev
depends_on: [T-015]
decisions: [0004, 0006]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/input/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/
  - client-android/app/src/test/kotlin/dev/matebridge/client/input/
---

## Amaç

Tabletten Mac'e kalem ve dokunma: PROTOCOL.md §4 (PEN, POINTER_ABS, PEN_GESTURE, RELEASE_ALL) ve §7 istemci yükümlülükleri. Faz 0 ölçümleri: NOTES 2026-09-29 "Girdi probu sonuçları".

## Kabul kriterleri

- [ ] **Kalem**: `onTouchEvent` + `onGenericMotionEvent` (hover) → bir `MotionEvent`'in tüm geçmiş örnekleri + güncel örnek tek PEN mesajında (en çok 64), `dt_us` azalmayan. Bayraklar: `IN_RANGE`, `CONTACT`, `STROKE_START` (yalnız `ACTION_DOWN` örneği), `BUTTON` (buttonState). `HOVER_EXIT` / `ACTION_CANCEL` → `flags=0` örnek. Silgi: `TOOL_TYPE_ERASER` → `tool=1`.
- [ ] Eğim: §4 geçici dönüşüm (`tilt_x = sinθ·sinφ`, `tilt_y = −sinθ·cosφ`), temas sırasında son bilinen değer tekrarlanır. Basınç u16. Koordinatlar T-015'in `VideoViewport`'u ile normalize (tek yer).
- [ ] **Menzil canlılığı**: `IN_RANGE` iken 100 ms'de bir yeni örnek yoksa son örnek güncel zamanla tekrar gönderilir.
- [ ] **PEN_GESTURE**: M-Pencil çift dokunma (`keyCode 718 / scanCode 190`, iki kısa DOWN/UP) → tek `DOUBLE_TAP`; bu tuş olayları KEY olarak gitmez.
- [ ] **Dokunma**: tek parmak → `POINTER_ABS source=TOUCH` (basılı = LEFT); iki parmak → `SCROLL` (BEGAN/CHANGED/ENDED, Mac nokta ölçeği `STREAM_CONFIG.width_pt`). **Avuç reddi / çizimde parmak kapalı** (karar 0006): kalem `IN_RANGE` iken ve son kalem örneğinden sonraki 1 sn boyunca yeni parmak basışları gönderilmez (bırakışlar her zaman gönderilir). Ayarlarda "Parmak dokunmasını tamamen kapat" seçeneği (varsayılan kapalı değil).
- [ ] **RELEASE_ALL**: arka plan, odak kaybı, cihaz ayrılması; sonrasında kalem temasının ortası gönderilmez (§7).
- [ ] **Tek sıralı FIFO** (§7): tüm girdi mesajları UI iş parçacığından, üretildiği sırayla T-012'nin sınırlı gönderim kuyruğuna; tıkanmada yalnızca hover örnekleri ve SCROLL CHANGED birleştirilir (§5).
- [ ] Saf dönüşüm/toplama mantığı JVM testli (MotionEvent'ten bağımsız bir ara model üzerinden); fixture'larla bayt uyumu zaten T-009'da.
- [ ] Loglama: `MB/input` saniyede bir özet (örnek/sn, mesaj/sn, avuç reddi sayısı); koordinat/karakter yok.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
