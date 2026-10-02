---
id: T-144
title: "Çizim" modunu ekle (120 fps, %90) ve ölçek deneme parametresi
status: doing
phase: 5
owner: android-client-dev
depends_on: [T-143]
decisions: [0017]
files:
  - client-android/app/src/
  - backlog/tasks/T-144-drawing-mode.md
---

## Amaç

Karar 0017: kalemle çizimde neredeyse tam netlikte kararlı 120 fps veren "Çizim" modu. Akıcı (%100) çözücü tavanında ~100–110 fps kalıyor, Performans (%75) ise ince çizgileri yumuşatıyor.

## Kapsam dışı

- Protokol, host. Diğer modların değerleri. Oyun katmanı (Çizim'de yok).

## Kabul kriterleri

- [ ] `StreamMode`: yeni `DRAWING` ("Çizim", id `drawing`, 120 fps, 900). Sıra: Netlik → Akıcı → Çizim → Performans → Oyun 120 → Oyun 60 (döngü ve panel listeleri). `isGame` değil. Bildirim metni "Çizim: 120 fps, %90".
- [ ] Açılış parametresi `--ei draw_scale N` (500–1000 dışı sıkıştırılır): yalnız o çalıştırma için Çizim modunun gönderdiği `scale_permille`'i değiştirir, kaydedilmez. Bildirim ve kaplama gerçek değeri gösterir (ör. "Çizim: 120 fps, %85"). Açılışta bir kez `session ev=draw_scale permille=N` loglanır (yalnız parametre verilmişse).
- [ ] Kayıtlı modu `drawing` olanlar açılışta Çizim'le başlar. Bilinmeyen id yine varsayılana düşer.
- [ ] JVM testleri: döngü sırası, `parse("drawing")`, `draw_scale` sıkıştırma ve yalnız Çizim'i etkilemesi, Çizim'in oyun katmanı kurmaması.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

1. `StreamMode`: `DRAWING("drawing","Çizim",120,900)` SMOOTH ile PERFORMANCE arasına; `toPrefs`/`toastText` isteğe bağlı `drawScale: Int?` alır (yalnız DRAWING'de etkili, `clampDrawScale` 500–1000).
2. `GameModeSettings.prefs(mode, drawScale)` parametreyi iletir (oyun katmanı DRAWING için kurulmaz, `isGame` false).
3. `MainActivity`: `draw_scale` extra'sı açılışta okunur, bir kez `session ev=draw_scale permille=N` loglanır; tüm `prefs`/`toastText` çağrıları parametreyi geçirir.
4. Testler: sıra, parse, sıkıştırma, yalnız Çizim etkilenir, oyun katmanı yok; mevcut döngü testi güncellenir.

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
