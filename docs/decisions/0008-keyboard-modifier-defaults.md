# 0008 — Klavye: varsayılan değiştirici eşlemesi ve ISO düzeni

- **Durum:** kabul (orkestratör varsayılanı; kullanıcı kullanımda değiştirmek isterse ayar Faz 4'te)
- **Tarih:** 2026-09-30

## Bağlam
Karar 0003: tablet fiziksel tuş kodu gönderir, karakteri Mac'teki giriş kaynağı üretir. Mac'te seçili düzen **"Turkish-QWERTY-PC"** (`com.apple.HIToolbox`). Huawei Glide Keyboard'da uygulamaya ulaşan bir Cmd/Meta tuşu yok (NOTES 2026-09-29, T-003): Fn ve halka tuşu sistemde kalıyor. Kullanıcı 2026-09-30'da "müdahalemi en aza indir" dedi; varsayılanı orkestratör seçti.

## Karar
1. **Varsayılan eşleme** (evdev scan code → macOS):
   - Sol Ctrl (29) → **Command** (sol), sağ Ctrl (97) → **Command** (sağ). Mac kısayolları (Cmd+C/V/Z/S/Tab) PC'deki Ctrl alışkanlığıyla aynı parmakla çalışır.
   - Sol Alt (56) → **Option** (sol), sağ Alt/AltGr (100) → **Option** (sağ). Turkish-QWERTY-PC düzeninde AltGr karakterleri (@, €, [, ] …) sağ Option ile üretilir; PC'deki AltGr+Q = @ alışkanlığı korunur.
   - Meta/Win (125/126) gelirse → **Control**. (Glide Keyboard'da bugün gelmiyor; gerçek Control şimdilik yok.)
2. Eşleme tek bir tablo/ayar nesnesidir (`MateBridgeCore`); "Ctrl↔Cmd takası" ve Control için başka bir tuş seçimi Faz 4 ayarlarında açılır.
3. **ISO düzeni:** Huawei klavyesi ISO (102. tuş `<>` var). Host, Mac'e ISO klavye gibi davranır: sol üstteki tuş (evdev 41, TR'de `"`) ve 102. tuş (evdev 86, TR'de `<`) macOS'un ISO klavyede ürettiği virtual keycode'lara eşlenir (0x0A `kVK_ISO_Section` ve 0x32 `kVK_ANSI_Grave` takası) ve olay kaynağının klavye türü ISO olarak ayarlanır. Doğru karakterlerin çıktığı cihazda doğrulanır; yanlışsa yalnızca tablo değişir.

## Sonuçlar
- Kod yazarken gerçek Control gereken yerler (terminalde Ctrl+C, Emacs tuşları) varsayılanda yok. Kullanıcı ihtiyaç duyarsa Faz 4 ayarı ya da bu kararın güncellemesi.
- Tekrar düşünülür: kullanıcı farklı bir eşleme isterse ya da başka bir klavye (Meta tuşlu) kullanılırsa.
