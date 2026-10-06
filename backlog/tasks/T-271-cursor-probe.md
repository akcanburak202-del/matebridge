---
id: T-271
title: Mac probu — yerel imleç: başka uygulamaların imleç şekli, gizli durumu ve değişim maliyeti herkese açık API ile okunabiliyor mu
status: review
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

1. `probes/cursor-probe/` SwiftPM paketi: `CursorProbeCore` (argüman ayrıştırma, değişim izleyici, özet/karma, süre istatistiği, kayıt satırı biçimi; birim testli) + `cursor-probe` çalıştırılabilir (örnekleyiciler, `once` ve `record` modları).
2. Adaylar yalnız herkese açık API: `NSCursor.currentSystem`, `NSCursor.current`, `CGCursorIsVisible` (dlsym), `CGEvent(source:nil).location`, `NSEvent.mouseLocation`, `CGWindowListCopyWindowInfo` ("Cursor" penceresi). Pencere yok (`.prohibited`), girdi enjeksiyonu yok.
3. `once`: adayları dener, çağrı maliyetini ölçer. `record`: 60/120 Hz yoklama, yalnız değişimleri yazar, PNG dökümü, CPU payı.
4. Ajan ortamında `once` ve kısa `record` çalıştırılır; kullanıcılı kayıt adımı Handoff'a yazılır.

## Handoff

- **Commit:** `709bfa1` (kod + Plan); Handoff ayrı commit. Dal `task/T-271-cursor-probe`.
- **Dosyalar:** `probes/cursor-probe/**` (Package.swift, `CursorProbeCore`, `cursor-probe`, testler, README), bu kart. `probes/README.md` tablosu `files:` listesinde olmadığı için güncellenmedi (orkestratör bir satır ekleyebilir).
- **check.sh:** `ALL OK` (probe `full run` kapsamında derlenir ve 12 birim test geçer).
- **Güvenlik:** pencere açılmadı (`NSApplication` `.prohibited`), imleç hareket ettirilmedi, girdi enjekte edilmedi, CGS* yok, çalışan host'a dokunulmadı. Ajan yalnız okudu.

### Ajan ortamında doğrulananlar (macOS 27.0.1, sanal ekran 1400x920 pt, release derleme)

Not: imleç o sırada bir metin alanı üstündeydi (başka uygulama), yani sistem imleci I-beam idi. Gerçek çeşitlilik (bağlantı, kenar, Krita) kullanıcı adımında.

| Aday | Çalışıyor mu | Başka uygulamanın imlecini veriyor mu | Maliyet |
|---|---|---|---|
| `NSCursor.currentSystem` | Evet, `NSApplication` başlatmadan da, oturum/izin hatası yok. Görüntü, hotspot, temsil boyutları (18x36 px, 9x18 pt, 2x, hotspot 4,9 = I-beam merkezi) doğru; PNG gözle I-beam. | **Evet** (çalışan süreç pencere sahibi değil, yine de metin alanı I-beam'i geldi) | nesne ~10-12 µs, nesne + RGBA çizim + karma ~23 µs (sıcak döngü). Her çağrı **yeni nesne** döner (200 çağrıda 200 farklı), kimlikle önbellek yok. 60 Hz sabit tempoda p50 ~130 µs (çekirdekler boşta soğuyor). |
| `NSCursor.current` | Çalışır ama yalnız **bu sürecin** imleci: 28x40 pt, 10x ölçekli varsayılan ok (gölgeli), hotspot 5,5. | Hayır | ~0 µs (nesne), görüntü çizimi 280x400 px yüzünden ~0,2-0,6 ms |
| `CGCursorIsVisible` (dlsym; herkese açık, kullanımdan kalkmış) | Sembol var, çağrı çalışıyor. Kayıtlarda çoğunlukla 1 (görünür); bir `record` çalışmasında 0 döndü (ben bir şey gizlemedim; o sırada başka bir şey imleci gizlemiş olmalı). Yani **hide-until-typing durumunu yansıtıyor olabilir, ama kanıtlanmadı**. | belirsiz (kullanıcı adımı 3) | ~2 ns |
| `CGEvent(source:nil)?.location` | Evet, noktalar, sol-üst orijin (445,211 gibi). | n/a | ~50 ns |
| `NSEvent.mouseLocation` | Evet, alt-sol orijin (y = 920 - y). | n/a | ~15 ns |
| `CGWindowListCopyWindowInfo` "Cursor" penceresi | Evet: Window Server'ın `name=Cursor layer=2147483630` penceresi var; boyutu (9x18) `currentSystem` ile aynı, sol-üst köşesi = konum - hotspot (508,153 = 512,162 - 4,9) yani **hotspot'u da veriyor**, alpha 1,0. Bir kayıtta pencere yoktu ("absent"), bu imlecin gizli olduğu ana denk geliyor olabilir (kanıtlanmadı). Ekran kaydı izni gerektirmedi bu ortamda (üst süreç izni olabilir, belirsiz). | evet (WindowServer'ın kendi penceresi) | ~110 µs sıcak, 0,5-0,9 ms sabit tempoda: yalnız ~10 Hz yoklanabilir |

Yoklama maliyeti (`record`, tüm adaylar, `currentSystem` her tick, `current` + pencere listesi 10 Hz): 60 Hz ~%1,9 bir çekirdek, 120 Hz ~%4,5 bir çekirdek (hassas tempo için son 200 µs'de spin dahil; üründe `.strict` zamanlayıcı kullanılırsa daha düşük olur). Ölçülen tempo sapması p99 < 0,1 ms (nanosleep'in %20'lik birleştirmesini yarılama + spin ile aştım; ham `nanosleep` 16 ms için ~3 ms geç kalıyor, ürün zamanlayıcısı için not).

### Bilinen sınırlar / bilinmeyenler

- **Yalnız I-beam ve sistem varsayılan imleci gözlendi.** Resize, bağlantı eli, Krita özel fırça imleci, oyun/gizli imleç henüz görülmedi.
- Gizli durum için güvenilir tek bir herkese açık yol kanıtlanmadı. Adaylar: `CGCursorIsVisible` ve "Cursor" penceresinin varlığı/alpha'sı; ikisi de yazarken gizlenmeyi yansıtıyor mu, kullanıcı adımı ile belli olacak. Yansıtmazsa tek yol özel API (`CGSCursorIsVisible`/`CGSGetCurrentCursorLocation` türü, **kullanılmadı**, AGENTS.md uyarınca ayrı karar ister) ya da klavye etkinliğinden çıkarım (yazı yazılınca gizli say, fare hareketinde göster).
- `currentSystem` değişimi için bildirim yok; yoklama gerekir. Her çağrı yeni nesne döndüğü için değişim yalnız görüntü karması + hotspot ile algılanır (probe bunu yapıyor, ~23 µs).
- Çok-ekran, HiDPI ölçeği: imge `scale=2.0` (18x36 px / 9x18 pt). İmleç boyutu erişilebilirlik ayarıyla büyüyebilir, o zaman temsil boyutları değişir (denenmedi).
- Dış monitör/sanal ekran farkı (imleç sanal ekranda iken şekil/ölçek aynı mı) denenmedi.

### Kullanıcılı kayıt adımı (orkestratör çalıştırır; kullanıcı tabletten çalışırken)

Mac'te GUI açılmaz; terminal ya da ssh/agent kabuğundan:

```bash
cd probes/cursor-probe && swift build -c release
.build/release/cursor-probe record --seconds 90 --hz 60 --out /tmp/cursor-rec.txt --dump-dir /tmp/cursor-dump
```

Başlar başlamaz, 90 sn içinde **tabletten** (normal çalışma gibi) sırayla, her birinde ~5 sn bekleyerek:
1. imleci boş masaüstünde, sonra bir metin alanında (I-beam) gezdir,
2. pencere kenarı/köşesinde (yeniden boyutlandırma imleci),
3. bir bağlantı üzerinde (el),
4. Krita'da fırça imleci (varsa özel imleç) ve kalemle hover,
5. metin alanında **yazı yaz** (imleç gizlenir; tuş içeriği kaydedilmez, yalnız görünürlük), sonra fareyi oynat (geri gelir),
6. isteğe bağlı: oyun/oyun modu (imleç gizli/özel).

Sonra bak: `grep -v ' pos ' /tmp/cursor-rec.txt` (shape/visible/cursorwindow satırları) ve `ls /tmp/cursor-dump` (her farklı şekil bir PNG; Read ile gözle kontrol, ölçek adı dosyada). Özet satırı sonda (`# summary`) ve ekrana yazdırılan CPU/tick maliyeti. Beklenen cevaplar: (a) her imleç değişiminde yeni `shape src=currentSystem` satırı var mı, (b) yazarken `visible src=CGCursorIsVisible value=0` ve/veya `cursorwindow absent` geliyor mu, (c) PNG'ler doğru mu, (d) Krita'nın özel imleci geliyor mu. 120 Hz için `--hz 120` ile tekrarlanabilir. Sonuç `docs/NOTES.md`'ye yazılmalı. Kayıt konum içerir, repoya konmaz.

### Sonraki adım önerisi

Şekil okuma uygun görünüyor (herkese açık, ~25 µs, 60 Hz'de ~%1-2 çekirdek; ürün daha az yoklar). Karar öncesi kalan tek büyük belirsizlik gizli durum (adım 5). Olumluysa: karar kaydı, `CURSOR_SHAPE` (id + PNG/RGBA + hotspot + ölçek) ve `CURSOR_STATE` (konum + görünür) mesajları, yalnız şekil değişince şekil gönderimi, konum her enjeksiyon sonrası. Gizli durum herkese açık yolla çözülmezse imleç gizliliği klavye etkinliğinden çıkarılabilir.

## Open questions

- `probes/README.md` tablosuna `cursor-probe` satırı eklenmedi (`files:` dışı).
- `CGCursorIsVisible` ve "Cursor" penceresinin yazarken gizlenmeyi yansıtıp yansıtmadığı kullanıcı adımına bağlı.
