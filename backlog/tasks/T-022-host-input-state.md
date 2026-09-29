---
id: T-022
title: Mac girdi durum makinesi — kalem, işaretçi, dokunma, release-all (saf, testli)
status: todo
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

- [ ] `InputStateMachine` (Core): girdi mesajları + zaman (`now`) alır, sıralı `InjectAction` listesi üretir: proximity enter/leave (araç tipiyle), mouse down/drag/up/move (tablet-point alt tipi, basınç, eğim), buton down/up, scroll başla/değişti/bitti. Koordinat dönüşümü bu katmanda yok (normalize değerler geçer); dönüşüm T-023'te tek yerde.
- [ ] PEN durum makinesi §4 tablosunun **her satırı**: `IN_RANGE`/`CONTACT` geçişleri, aynı örnekte enter+down, `CONTACT=1 IN_RANGE=0` → `flags=0`, araç değişimi (up+leave+enter), `STROKE_START`.
- [ ] **Kilit (latch)**: her release-all sonrası `CONTACT=1` örnekler `CONTACT=0` veya `STROKE_START` gelene kadar hover sayılır.
- [ ] **Watchdog'lar**: kalem `IN_RANGE` iken 500 ms örnek yoksa up+leave; SCROLL açıkken 500 ms mesaj yoksa bitir.
- [ ] **Kaynak ayrımı / sol düğme sahipliği** (§7): tek sahip; kalem önceliği (başka kaynak basılıyken kalem teması → önce o kaynak adına up, sonra kalem down); sahip olmayan kaynağın bırakması etkisiz; kalem temas halindeyken diğer kaynakların sol basışı yok sayılır; diğer düğmeler OR; kalem `IN_RANGE` iken TOUCH yeni basışları yok sayılır ama **sahibin bırakışı asla** yok sayılmaz.
- [ ] **Release-all** (her tetikleyici: mesaj, BYE, kopma, 1,5 sn sessizlik, devralma, kapanış): tüm basılı düğmeler up, kalem up+leave, scroll bitir, kilit kur. Çağrılabilir API + `releaseAll(reason)`.
- [ ] **PEN_GESTURE DOUBLE_TAP → silgi modu aç/kapa** (karar 0006): silgi modunda kalem örnekleri `tool=ERASER` sayılır (araç değişimi kuralı: gerekirse up, leave, eraser olarak enter). Mod release-all ve oturum sonunda kalem moduna döner. Tabletten gelen gerçek `tool=ERASER` doğrudan silgidir.
- [ ] **Parmak kapısı** (karar 0006): kalem `IN_RANGE` iken ve son kalem örneğinden sonraki 1 sn boyunca TOUCH yeni basışları yok sayılır. Sahibin bırakışı her zaman işlenir.
- [ ] Testler: §4/§7'deki her kural için en az bir test; ayrıca rastgele (property/fuzz) test: rastgele mesaj dizileri + rastgele release-all sonrası **"hiçbir basılı durum kalmadı"** değişmezi ve "her down'un bir up'ı var" değişmezi.
- [ ] `./scripts/check.sh` geçiyor.

## Notlar

- Kritik: bu kart Codex `--high` incelemesinden geçer.

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
