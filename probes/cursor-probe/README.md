# cursor-probe (T-271)

Soru: host, o an ekrandaki imlecin şeklini, gizli/görünür durumunu ve konumunu **herkese açık API** ile, düşük maliyetle ve doğru okuyabiliyor mu? (Yerel imleç fikri, `docs/research/2026-10-06-ideas-cursor-usb-lossless.md` §1.) Ürün kodu değildir.

## Güvenlik sınırları

Pasif ve salt okunur. **Pencere açmaz** (`NSApplication` yalnız `.prohibited` politikasıyla), imleci hareket ettirmez, tıklamaz, girdi enjekte etmez, klavye/metin kaydetmez, özel API (`CGS*`) kullanmaz, çalışan MateBridge host'una dokunmaz. Kayıt dosyasına yalnız imleç şekli özeti (id, boyut, hotspot), görünürlük (0/1) ve imleç konumu yazılır.

## Çalıştırma

```bash
cd probes/cursor-probe
swift build -c release
.build/release/cursor-probe once                         # adayları dener, çağrı maliyetini yazar
.build/release/cursor-probe record --seconds 60 --hz 60 --out ~/Desktop/cursor-rec.txt --dump-dir ~/Desktop/cursor-dump
```

`record` bayrakları: `--hz 60|120` (varsayılan 60), `--dump-dir DIR` (görülen her farklı şekil için `cursor-<id>-<px>-<ölçek>x.png`), `--no-position`, `--no-windowlist`. Ctrl-C erken durdurur, özet yine yazılır.

## Adaylar

| Aday | Ne verir |
|---|---|
| `NSCursor.currentSystem` | sistem imlecinin görüntüsü, hotspot, temsil boyutları (şekil için ana aday) |
| `NSCursor.current` | karşılaştırma: yalnız bu sürecin imleci |
| `CGCursorIsVisible` (dlsym, kullanımdan kalkmış) | gizli/görünür |
| `CGEvent(source: nil)?.location`, `NSEvent.mouseLocation` | konum |
| `CGWindowListCopyWindowInfo` "Cursor" penceresi | Window Server'ın imleç penceresi: boyut, alpha, sol-üst köşe (konum - hotspot) |

Kayıt satırı biçimi: `<saniye> shape|visible|pos|cursorwindow key=value ...`. `shape` satırı yalnız şekil (görüntü özeti veya hotspot) değişince yazılır. Sonuçlar ve yorum: `backlog/tasks/T-271-cursor-probe.md` → Handoff.
