# 0036 — Yerel imleç: imleci videodan çıkarıp tablette çizmek

- **Durum:** kabul (kullanıcı 2026-10-06 "başlayabilirsin"; ayrıntılar orkestratör varsayılanı, kullanıcı değiştirebilir)
- **Tarih:** 2026-10-06

## Bağlam

İmleç bugün video karesinin içinde geliyor (`ScreenCapture.swift` `showsCursor = true`): trackpad, fare ve kalem hover'ında imleç ekrana videonun tüm gecikmesiyle (~40–55 ms) gelir. Fikir: `docs/research/2026-10-06-ideas-cursor-usb-lossless.md` §1. T-271 probu ve kullanıcılı kayıt (NOTES 2026-10-06 ~13:50): `NSCursor.currentSystem` başka uygulamaların imleç şeklini (ok, I-beam, el, yeniden boyutlandırma, "izin yok", uygulamanın özel imleçleri) herkese açık API ile ~25 µs'de veriyor; `CGCursorIsVisible` yazarken ve oyunda gizlenmeyi yakalıyor; konum okuması ~ns. USB kontrol RTT ~2–4 ms, Wi-Fi ~15 ms (NOTES ~15:25).

## Karar

1. **Kim çizer:** tablet, video yüzeyinin üstünde ayrı bir katmanda (SurfaceView üstü View/overlay; video yoluna dokunmaz). Host yerel imleç açıkken videoda imleci çizmez (`showsCursor = false`, akışı yeniden kurmadan `updateConfiguration`).
2. **Konum kaynağı (v1):** host'un gerçeği. Host imleç konumunu, görünürlüğünü ve şekil kimliğini her enjeksiyondan sonra ve ~120 Hz yoklamayla değişince gönderir (`CURSOR_STATE`, en yenisi kazanır, sınırlı). Tablette tahmin **yok** (v2'ye bırakıldı: göreli harekette hız çarpanı tablette bilindiği için tahmin mümkün; ölçüm sonrası). Beklenen gecikme: USB ~RTT/2 + bir vsync (~5–10 ms), Wi-Fi ~15–25 ms; bugün 40–55 ms.
3. **Şekil:** host şekli yalnız değişince ve tablet o kimliği bu oturumda görmediyse gönderir (`CURSOR_SHAPE`: kimlik, nokta boyutu, hotspot, PNG). Tablet oturum başına sınırlı önbellek tutar (≤ 32 şekil). Büyük şekiller (erişilebilirlik büyütmesi) 128 × 128 px'e küçültülür; PNG ≤ 60 KB.
4. **Modlar:** Günlük ve Çizim'de varsayılan **açık**, Oyun'da **kapalı** (oyun kendi imlecini çizer/gizler; video imleci kalır). Panelde "İmleç: Tablette / Görüntüde" (mod başına değil, tek ayar; Oyun'da her zaman Görüntüde).
5. **Açma/kapama:** istemci `CURSOR_PREFS(enabled)` gönderir (yalnız bit13 ile); host uygulayınca `CURSOR_STATE` akışı başlar ve videodan imleç kalkar. Kapatınca ya da oturum bitince host videoda imleci geri açar. Host açıkken en az 500 ms'de bir `CURSOR_STATE` gönderir (değişiklik olmasa da). İstemci katmanı 1,5 s'den uzun süre `CURSOR_STATE` almazsa imleci gizler ve `CURSOR_PREFS(0)` ile video imlecine döner (imleçsiz kalma olmaz).
6. **Girdi kurallarına dokunmaz:** yalnız görüntüleme; enjeksiyon aynı.
7. Protokol (orkestratör, Codex `--high`): HELLO bit13 `LOCAL_CURSOR`, 0x0B `CURSOR_PREFS` (C→H), 0x0C `CURSOR_SHAPE` (H→C), 0x0D `CURSOR_STATE` (H→C), fixture'lar.

## Sonuçlar

- İmleç ve tıklama hedefi neredeyse anında; pencere sürüklerken pencere imlecin ~40 ms gerisinde gelir (Parsec'teki gibi, kabul).
- Ekran görüntüsü/kayıt (Mac'te) imleci içermeye devam eder (sistem çizer); yalnız video akışından çıkar.
- İş: protokol + host (yoklama, şekil kodlama, `showsCursor`) + istemci (katman, önbellek, panel) ≈ 4–6 ajan günü, 1 cihaz oturumu.
- **Tekrar düşünülür:** v2 tablette tahmin (göreli ve mutlak hareket), kalem hover'ında imleç yerine kalem noktası.
