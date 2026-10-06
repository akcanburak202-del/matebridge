---
id: T-271
title: Mac probu — yerel imleç: başka uygulamaların imleç şekli, gizli durumu ve değişim maliyeti herkese açık API ile okunabiliyor mu
status: todo
phase: 6
owner: mac-host-dev
depends_on: []
decisions: []
files:
  - probes/cursor-probe/
  - backlog/tasks/T-271-cursor-probe.md
---

## Amaç

Fikir: imleci videodan çıkarıp tablette ayrı katmanda çizmek (`docs/research/2026-10-06-ideas-cursor-usb-lossless.md` §1 + orkestratör değerlendirmesi). Bu prob karar öncesi tek soruyu cevaplar: **host, o an ekrandaki imlecin şeklini (görüntü, hotspot, ölçek), gizli/görünür durumunu ve konumunu herkese açık API ile, düşük maliyetle ve doğru okuyabiliyor mu?** Ürün koduna dokunulmaz.

## Kabul

1. `probes/cursor-probe/`: bağımsız Swift paketi (ürün hedeflerine bağımlılık yok), komut satırı aracı. **Pencere açmaz**, Dock'ta görünmez (`NSApplication` gerekiyorsa `.prohibited`/`.accessory` politika), Mac'in tek ekranı tablettir. İmleci **hareket ettirmez**, tıklamaz, girdi enjekte etmez.
2. Adaylar (her biri için çalışıyor mu, başka uygulamanın imlecini veriyor mu, çağrı maliyeti µs): `NSCursor.currentSystem` (görüntü, `hotSpot`, `image.representations` piksel boyutu/ölçek), `NSCursor.current` (karşılaştırma için), konum (`CGEvent(source: nil)?.location` / `NSEvent.mouseLocation`), gizli durum için herkese açık bir yol var mı (`CGCursorIsVisible` kullanımdan kalkmış olsa da çalışıyor mu; yoksa ne). Özel API (`CGS*`) **kullanılmaz**; yalnız varlığı/gerekliliği not edilir (AGENTS.md: özel API ayrı karar ister).
3. Pasif kayıt modu: `cursor-probe record --seconds N --out <dosya>`: 60 Hz (ve 120 Hz) yoklama, şekil değişince (görüntü baytlarının özeti + boyut + hotspot) ve gizli/görünür değişince satır yazar; konum örnekleri ayrı; CPU payı (`getrusage`) sonda. Kullanıcı bunu çalıştırırken imleci metin alanı, pencere kenarı, bağlantı, Krita fırçası üzerinde gezdirecek, yazı yazacak (gizlenme) — bu adım orkestratörle, sonra.
4. Görüntü dışa aktarma: farklı her şekli PNG olarak kaydet (`--dump-dir`), ölçek (1x/2x) belirt; böylece doğruluğu gözle kontrol edilebilir (Read ile).
5. Ajan kendi ortamında yapabildiğini doğrular: araç derlenir, `NSCursor.currentSystem` bir değer döner mi (oturum/izin hatası varsa açıkça yaz), çağrı maliyeti. Kullanıcı gerektiren kısım Handoff'ta adım adım "nasıl çalıştırılır".
6. Rapor (Handoff): her aday için sonuç tablosu, yoklama maliyeti, bilinen sınırlar (ör. başka uygulamanın özel imlecini veriyor mu belirsizse belirt), sonraki adım önerisi.

## Plan

(ajan doldurur)

## Handoff

## Open questions
