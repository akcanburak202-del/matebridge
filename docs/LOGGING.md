# Runtime log kuralları

Loglar hem hata ayıklamanın hem de ajanların cihazdaki davranışı "görmesinin" tek yolu. Mac ve tabletteki loglar aynı oturum kimliğiyle eşleştirilebilmelidir.

## Satır formatı (her iki taraf)

```text
<mono_ms> <LEVEL> <component> sid=<session> gen=<n> ev=<event_name> key=value ...
```

- `mono_ms`: monoton saat (Mac: `ContinuousClock`/`mach_absolute_time`, Android: `SystemClock.elapsedRealtime`). Duvar saati ayrıca satır başına eklenebilir ama karşılaştırmalar monotonla yapılır.
- `LEVEL`: `E` hata, `W` uyarı, `I` bilgi, `D` debug (varsayılan kapalı).
- `component`: `capture`, `encoder`, `net`, `vdisplay`, `input`, `pen`, `kbd`, `decoder`, `render`, `session`.
- `ev`: snake_case olay adı, ör. `ev=connect_ok`, `ev=frame_drop reason=stale`.

## Nereye yazılır

| Taraf | Canlı | Dosya |
|---|---|---|
| Mac | `os.Logger` subsystem `dev.matebridge.host` | `~/Library/Logs/MateBridge/host.log` (döner, maks. 5×10 MB) |
| Android | `Log` tag `MB/<component>` (`adb logcat -s 'MB/*'`) | uygulama dizininde `logs/client.log` (döner), `adb` ile çekilir |

## Gizlilik (kesin kural)

- Tuş karakteri, metin, pano içeriği **asla** loglanmaz. Keycode yalnızca `D` seviyesinde.
- Ekran görüntüsü/kare içeriği loglanmaz.
- Loglar repoya commit'lenmez (`.gitignore`).

## Sayaçlar

Her 1 saniyede bir `ev=stats` satırı: fps, bitrate, kuyruk derinlikleri, düşürülen kare, girdi olay sayısı. Ekrandaki istatistik katmanı da aynı sayaçlardan beslenir.
