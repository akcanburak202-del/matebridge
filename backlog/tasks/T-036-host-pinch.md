---
id: T-036
title: Mac — PINCH kodeki, yakınlaştırma durum makinesi ve büyütme hareketi enjeksiyonu
status: in-progress
phase: 3
owner: mac-host-dev
depends_on: [T-032]
decisions: [0009]
files:
  - host-mac/Sources/MateBridgeCore/
  - host-mac/Sources/MateBridgeHost/Input/
  - host-mac/Tests/MateBridgeCoreTests/
  - backlog/tasks/T-036-host-pinch.md
---

## Amaç

PROTOCOL.md §4 `0x17 PINCH`, §5 (birleştirme), §7 (release-all, watchdog) ve karar 0009. Protokol değişikliği ve fixture'lar **`proto/pinch` dalında** (`c37b796`): bu kartın dalı oradan açılır. O dalda `swift test` yeni fixture'lar yüzünden kırmızı; bu kart yeşile döndürür.

## Kabul kriterleri

- [ ] **Kodek** (`MateBridgeCore`): `Pinch` mesajı (alanlar PROTOCOL'daki sırayla), `phase` ve `source` bilinmeyen değerde protokol hatası, kısa payload hatası, `scale` sonlu olmalı. Fixture testleri `pinch_began`, `pinch`, `pinch_ended` için decode/encode bayt bayt geçer.
- [ ] **Durum makinesi** (Core, saf, testli): tek açık PINCH; SCROLL ile karşılıklı dışlama (her iki yönde yeni BEGAN eskisini zorla bitirir); sol düğmenin sahibi varken BEGAN ve o hareketin devamı yok sayılır; BEGAN'sız CHANGED/ENDED yok sayılır; `source = TOUCH` için §7 parmak kuralı (kalem menzilde/son PEN'den 1 sn içinde yeni PINCH yok sayılır); 500 ms watchdog; release-all/oturum sonu/kapı kapanması "bitti" üretir. Mevcut SCROLL, kalem, klavye testleri geçer; fuzz testi PINCH'i de kapsar (açık hareket kalmaz, BEGAN'sız bitti yok).
- [ ] **Planlayıcı:** `MacEvent`'e büyütme olayı (faz: began/changed/ended, değer, konum, bayraklar). `TOUCH` kaynağında BEGAN'dan önce imleç merkeze taşınır (fare hareketi, sürüklemesiz; normalize → nokta dönüşümü mevcut `DisplayGeometry` ile). Sıfır değerli changed enjekte edilmez. Güncel klavye bayrakları (T-032 `stampFlags`) büyütme olayına da uygulanır. Kapatan olay (ended) `OwedRelease` kuralıyla her zaman üretilir ve başarısızsa yeniden denenir. CANCELLED → ended.
- [ ] **Enjeksiyon** (karar 0009): büyütme olayını üreten kod **tek bir dosya/tipte** (ör. `MagnifyGestureEvent.swift`): `CGEvent(source:)`, `type` = 29, alan 110 = 8, alan 132 = faz (began 1, changed 2, ended 4), alan 113 = değer (`Double`), konum = verilen nokta. Alan numaraları başka hiçbir yerde geçmez. Kaynak: Mac Mouse Fix `TouchSimulator.m` (atıf yorumda).
- [ ] `--inject-test` için `--pinch in|out` seçeneği (merkezde BEGAN + ~20 CHANGED + ENDED) — yalnızca eklenir, ÇALIŞTIRILMAZ.
- [ ] Log: sayaç `pinch_msgs`, olay `pinch_forced_end cause=…` (yalnızca durum değişimi; koordinat yok).
- [ ] `./scripts/check.sh` geçiyor.

## Kapsam dışı

- Tablet tarafı (T-037). Döndürme hareketi. Gerçek olay gönderme yok; cihaz testi orkestratörde (Krita'da tuval yakınlaşması, Safari/Preview).

## Plan

Sira: kodek -> durum makinesi -> planlayici -> poster/inject-test/log. Her adim testle.

1. **Kodek:** `MessageType.pinch = 0x17`, `PinchPhase` (1...4), `PinchSource` (0 touch, 1 touchpad), `Pinch` (time, scale f32 sonlu, x, y, phase, source, reserved); bilinmeyen phase/source ve kisa payload hata. `Message.pinch`, `SessionMachine.handleCommon` (aktif degilken yok sayilir, aktifken `deliver`). Fixture testleri `validFixtures`'a eklenir.
2. **Durum makinesi** (`InputStateMachine+Pinch.swift`): `pinchOpen`, `lastPinchAt`, `pinchWatchdogUs = 500 ms` (nextDeadline / reanchor / applyWatchdogs / releaseAll / hasHeldInput). Yeni `InjectAction.pinch(InjectPinchPhase, scale:, center:)`; `InjectPinchPhase` = began, changed, ended, cancelled, forcedEnd(cause). BEGAN: sol dugme sahibi varsa ya da TOUCH kapisi aktifse yok sayilir (acik hareket varsa o da zorla biter, boylece yoksayilan hareketin devami acik olana karismaz); aksi halde acik SCROLL ve PINCH zorla bitirilir, sonra began (TOUCH'ta merkezle). SCROLL BEGAN acik PINCH'i zorla bitirir. BEGAN'siz CHANGED/ENDED yok sayilir. Zorla bitirme nedenleri (`new_pinch`, `new_scroll`, `watchdog`, `release_all`, `ignored_began`) makinede birikir, pipeline bosaltir (log icin). `pinchMessages` sayaci.
3. **Planlayici:** `MacEvent.magnify(MacMagnify)` (faz began/changed/ended, deger Double, konum, bayraklar). Planner golge durumu `magnifyOpen`; began once (TOUCH ise) `mouse moved` ile imleci merkeze tasir (DisplayGeometry); sifir degerli changed dusurulur (keepalive); deger [-0.5, 1.0]'a sikistirilir; ended/cancelled/forcedEnd hep `ended` uretir ve kapi tarafindan engellenmez; `stampFlags`, `with(flags:)`, `position`, `moved`, `isClosing`, `notPosted`, `releaseAll`, `isHoldingInput` guncellenir. `OwedRelease.Slot.magnifyEnd` (sira 11): basarisiz ended yeniden denenir. `ReleaseRecord.pinchEnds`.
4. **Host:** `MagnifyGestureEvent.swift` (tek dosya: tip 29, alan 110/132/113, MMF atfi); `CGEventFactory.make` oraya yonlendirir. `InputController`: `.pinch` deliver, `pinch_msgs` oturum sonu logu, `pinch_forced_end cause=...` logu. `InjectTest`: `--pinch in|out` yalnizca eklenir, calistirilmaz.
5. Testler: kodek, durum makinesi (PINCH-*), planlayici, owed, pipeline, fuzz kapsami (InputFuzzTests + MacInputModel). `./scripts/check.sh`.

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
