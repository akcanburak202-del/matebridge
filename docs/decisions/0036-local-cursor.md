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

## Ek (2026-10-06, T-278): v2 tablette konum tahmini, protokol değişmeden

Kullanıcı onayladı (2026-10-06). Yalnız istemci çizimi değişir; `CURSOR_STATE` gerçek olarak kalır, girdi yoluna hiçbir şey geri beslenmez, protokol ve host aynı.

- **Tek kaynak:** tahmin yalnız göreli harekettendir (`POINTER_REL`: fare, trackpad). Host'un imleci kimin taşıyabileceği kuralları (sol düğme sahibi, kalem yakınlığı, parmak kapısı, araç değişimi) istemcide aynalanmaz: aynalamak host'tan sapıp durdu. Herhangi bir `PEN` örneği ya da `POINTER_ABS` (parmak, yakalama dışı fare) tahmini son örnekten **300 ms** sonrasına dek askıya alır; o sürede host'un bildirdiği konum çizilir (v1 gecikmesi; kalemin zaten kendi yerel geri bildirimi var). Fare/trackpad düğmesi basılıyken (sürükleme) göreli tahmin aynen sürer.
- **Model:** tablet gönderdiği her `POINTER_REL` deltasını (nokta) gönderim anıyla 512'lik halkada tutar. Tahmin = son kabul edilen durum + o durumun host'ta örneklendiği andan sonra host'a varmış sayılan deltalar (varış = gönderim + RTT/2). Durumun örnekleme anı: `host_time_us − saat_farkı`, en çok `varış − RTT/2`; saat farkı yoksa `varış − RTT/2`. Deltalar her adımda `STREAM_CONFIG` nokta boyutuna sıkıştırılır (Mac kenarda durur).
- **Nesil:** her gözlem, gönderildiği kontrol bağlantısının nesil numarasını taşır; eski nesil (geçiş/yeniden bağlanma yarışı) yok sayılır. Halka oturum başında ve sonunda boşaltılır.
- **Uzlaştırma:** yeni durum gelince eski ve yeni tahmin arasındaki fark ≤ 4 pt ise ekranda görünen konum korunur ve ~10 ms zaman sabitiyle erir (1–2 kare); büyükse anında atlar (uygulama imleci taşıdı). 100 ms'den eski olaylar "yerleşti" sayılır: hareket durunca ya da host hareketi yok saydığında tahmin ≤ 100 ms içinde host konumuna döner.
- **Kapalı olduğu yerler:** imleç "Görüntüde", Oyun modu, `visible=0`, stream boyutu bilinmiyor; geliştirici anahtarı `--ez dev true --ez cursor_predict false` (v1 çizimi, A/B).
- **Ölçüm:** `cursor_stats` satırına `pred_err_pt_p50/p95` (önceki durumun, yeni durumun örnekleme anına tahmini ile gerçek konum farkı, Mac noktası), `pred_n`, ve karşılaştırma için `hold_err_pt_p50/p95` (hiç tahmin etmeseydik, yani v1 gibi son durumda kalsaydık fark). `pred_err` `hold_err`'den belirgin küçükse tahmin işe yarıyor.
- **Bilinen sınır:** saat farkı belirsizliği (RTT/2) olay kesimini kaydırır; Wi-Fi'da sistematik sapma `pred_err`'de görünür. Kalem hover'ı ve parmak v2'de yok (askıya alma); ileride istenirse host'un kaynak kararını protokolle bildirmesi gerekir (istemci aynalamaz).
