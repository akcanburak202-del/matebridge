# Oyun modu gözden geçirmesi: görüntü kalitesi, Mac yükü, çözünürlük seçenekleri (2026-10-23)

Kod değişikliği yok. Kaynaklar: kararlar 0014, 0016, 0029, 0030, 0032, 0033, 0034, 0039; NOTES 2026-10-03 ~00:10, 2026-10-04 ~10:50 ve ~14:20, 2026-10-05 ~16:40 ve ~18:40, 2026-10-08 ~22:37, 2026-10-20 22:30 (TotK uzun oturum); `docs/research/2026-10-07-perf-profile.md`; kod: `GameMode.kt`, `GameResolution.kt`, `Bitrate.kt`, `ColourChoice.kt`, `StreamPrefsPolicy.swift`, `HEVCEncoder.swift`, `ScreenCapture.swift`.

## Bugünkü durum

| | Değer | Kaynak |
|---|---|---|
| Ekran | 1x oyun ekranı, varsayılan 1848×1214; 1400×920 · 2100×1380 · 2240×1472 · 2800×1840 (deneysel) | 0029, 0030 |
| Kare hızı | Oyun 60 varsayılan; sanal ekran 60 Hz | 0016, 0030 |
| Bit hızı | Otomatik = **60 Mbps sabit** (oyun katmanı; çözünürlük, kare hızı ve bağlantıdan bağımsız). Host'un kendi mod varsayılanı 1848@60 için 20 Mbps olurdu, istemci katmanı onu ezer | `GameMode.kt` `GAME_BITRATE_KBPS`, `StreamPrefsPolicy.defaultBitrateKbps` |
| Renk | Kalıcı "Renk" ayarı, varsayılan Keskin kenarlar; Oyun'da da uygulanır (HDR açıkken Normal) | 0033, 0034 eki |
| Kodlayıcı | HEVC, `RealTime=false`, `PrioritizeEncodingSpeedOverQuality=true`, yeniden sıralama yok | `HEVCEncoder.swift` |
| Performans artışı | Ayar, varsayılan kapalı | 0039 |

## Bulgular

### 1. MateBridge'in Mac yükü küçük; asıl yük oyunun kendisi

- Oyun 60'ta MateBridgeApp ~%11–14 tek çekirdek, VTEncoderXPCService ~%2, WindowServer ~%12–13 (perf profili (c), 2026-10-03 tablosu). `sample` çıktısında %2'yi geçen tek kalem yok.
- Oyun 120 → 60: RE4'te Mac GPU %90 → %54, oyun CPU %234 → %158 (2026-10-03). Kumanda/klavyeyle panel 60 Hz'de kaldığı için (T-140, 0041 reddi) Oyun 120 bu kullanımda yük getirir, kazanç getirmez.
- Oyunun çizim yükü kabaca piksel sayısıyla ölçeklenir: 2800×1840 = 1848×1214'ün 2,3 katı, 2240×1472 = 1,47 katı.
- Yakalama sanal ekran hızında; Oyun 60'ta ekran 60 Hz olduğu için ayrı kısma gerekmez.

### 2. Bit hızı çözünürlüğe göre ayarlanmıyor

Piksel başına bit (60 fps; 120 fps'te yarısı):

| Akış | Bit hızı | Mpx | bit/piksel |
|---|---|---|---|
| Günlük 2800×1840 (host varsayılanı, kullanıcı kaliteden memnun) | 30 Mbps | 5,15 | 0,10 |
| Oyun 2800×1840 | 60 | 5,15 | 0,19 |
| Oyun 2240×1472 | 60 | 3,30 | 0,30 |
| Oyun 2100×1380 | 60 | 2,90 | 0,35 |
| **Oyun 1848×1214 (varsayılan)** | 60 | 2,24 | **0,45** |
| Oyun 1400×920 | 60 | 1,29 | 0,78 |
| Oyun 1848×1214, öneri | 30 | 2,24 | 0,22 |

- Oyun varsayılanı Günlük modun ~4,5 katı bit/piksel harcıyor. Oyun içeriği masaüstü yazısından daha zor kodlanır, ama 30 Mbps'te bile pay ~2 katta kalır. [Çıkarım: görünür kalite farkı beklenmez; ölçülecek.]
- Bedeli Wi-Fi ödüyor: TotK 2 saat (2026-10-20), 60 Mbps, Wi-Fi: >150 ms takılma 55 kez, 54'ünden hemen önce video TCP'de yeniden gönderim ya da rtt > 50 ms; saniyelerin %35'inde yeniden gönderim. 2026-10-08 22:45'te aynı ağda 30 Mbps'e inince tablet ping'i 17–41 ms → 3–5 ms, takılma yok.
- Tablet çözücüsünde bit hızı ucuz (T-249: 60 → 100 Mbps ~+1 ms), yani kazanç çözücüde değil ağda.
- Mac'te bit hızının etkisi yok denecek kadar küçük (donanım kodlayıcı).

### 3. Oyunda Keskin renk Mac GPU'sunda iş yapıyor, faydası küçük

- Keskin kenarlar SCK'yi `420f` yerine BGRA'da yakalatır (kare başına 2,7 kat bellek) ve her kareye bir Metal geçişi ekler: 2800'de `gpu_ms` p50 ~2,5–4,2 ms (GPU saat durumuna bağlı, NOTES 2026-10-08 ~15:00), yakalama→kodlama ~+3 ms (0033).
- Faydası doygun renkli yazı ve ikon kenarlarında; oyun sahnelerinde (doğal görüntü, hareket) küçük. Aynı GPU'yu oyun kullanıyor; geçiş ve bellek trafiği oyunla yarışıyor.
- 4:4:4 araştırması (2026-10-05-yuv444.md, adım B) "Oyun'da GPU yükü yüzünden belki kapalı" notunu düşmüştü; karar verilmedi.
- Oyun çözünürlüğünde (1848) ölçüm yok. Mac GPU sayıları yalnız dönüşümlü A/B ile kıyaslanır (T-311 dersi).

### 4. Çözünürlük listesi

- **2100×1380 ile 2240×1472 arasındaki fark %14 piksel.** Kullanıcı 1848 ile 2240 arasında fark hissetmedi (2026-10-04 ~14:20). İkisini birden tutmanın gerekçesi zayıf.
- **2800×1840 "(deneysel)"** etiketi cihaz doğrulamasını bekliyor (0030 T-250 eki: 1x 2800 oyun ekranı, kalem koordinatları, Mac GPU yükü). Doğrulama yapılmadı.
- **1848 varsayılan olarak doğru.** Performans artışı kapalıyken 2240@60'ta çözme p95 ~17,8 ms > 16,7 ms; ~%2–3 iki-vsync kare. Artış açıkken 1848'de çözme p50 ~11 ms (TotK). 2240 artışla ölçülmedi.
- 1400×920 tam 2 kat (tamsayı) büyür; diğerleri tamsayı değil. Tablet ölçekleyicisi her durumda yumuşattığı için bunun pratik etkisi küçük. [Çıkarım.]

### 5. Önerilmeyenler

- Kodlayıcıda `PrioritizeEncodingSpeedOverQuality` kapatmak: bit başına kaliteyi artırır ama kare başına ~5–15 ms ekler (T-086: 2800'de ~25 ms). Oyunda gecikme önceliği var (0014).
- Yakalamayı host'ta ayrıca kısmak: sanal ekran zaten 60 Hz.
- Oyunun kendi yükü (oyun içi 60 fps sınırı ya da dikey senkron, render ölçeği) MateBridge'in elinde değil; kullanıcıya not.

## Öneriler (ölçüme bağlı)

| # | Öneri | Beklenen kazanç | Doğrulama |
|---|---|---|---|
| Ö1 | Oyun Otomatik bit hızı çözünürlüğe, kare hızına ve bağlantıya göre (ör. Wi-Fi 1848@60 → 30 Mbps; USB 60 kalabilir) | Wi-Fi takılmaları azalır; görsel fark beklenmez | A1 |
| Ö2 | Oyun katmanına geçici "Renk: Normal" (0014 §3 gibi; Günlük/Çizim değişmez) | Mac GPU'da kare başına bir geçiş ve BGRA trafiği eksilir, ~3 ms daha az gecikme | A2 |
| Ö3 | Liste: 1400 · 1848 · 2240 · 2800 (2100 çıkar); 2800 doğrulanır ya da çıkar | Sadelik | A3, A4 |

## Ölçüm planı (T-364)

Kural: her koşul **en az 3 kol**, dönüşümlü (A B A B A B), aynı oyun ve sahne, aynı derleme. Kol başına ~90–120 sn. Ayar değişimi kullanıcı panelinden; bit hızı ve renk değişimi sanal ekranı yeniden kurmaz (yalnız yakalama + kodlayıcı), çözünürlük değişimi kurar (~1 sn; oyun kendi çözünürlüğünü yeniden seçmek zorunda kalabilir, NOTES 2026-10-04 ~14:20). Kaydı `tools/measure/game-ab.sh` alır (T-364); kolun gerçekten uygulandığını loglardan doğrular.

| Test | Sabit | Kollar | Taşıma |
|---|---|---|---|
| A1 bit hızı | Oyun 60, 1848, renk kullanıcının ayarı, Performans artışı kullanıcının ayarı | 60 ↔ 30 Mbps | Wi-Fi (sorunun olduğu yol) |
| A2 renk | Oyun 60, 1848, A1'in kazanan bit hızı | Keskin ↔ Normal | aynı |
| A3 çözünürlük | Oyun 60, Performans artışı **açık** | 1848 ↔ 2240 | aynı |
| A4 (isteğe bağlı) | Oyun 60, 2800 | tek kol, 1–2 dk | aynı |

Kol başına kaydedilenler: gönderilen Mbps, video TCP yeniden gönderim (toplam, saniyelerin yüzdesi), srtt p50/p95, KEYFRAME isteği; tablet alınan fps, `skip_pct`, çözme p50/p95, yakalama→çözme p50/p95/p99, >150 ms takılma sayısı; Mac GPU kullanımı p50, `gpu_ms` p50/p95, MateBridgeApp / WindowServer / VTEncoder / oyun CPU; kullanıcının görsel notu (A1'de kol bilgisini bilmeden verirse daha iyi).

### Karar kuralları (ölçümden ÖNCE yazıldı; sonradan değişmez)

- **A1:** 30 Mbps kollarının hepsinde >150 ms takılma sayısı ve yeniden gönderimli saniye yüzdesi 60'tan kötü değilse **ve** kullanıcı 30'da görsel kayıp görmüyorsa → Ö1 karar ekine gider (Wi-Fi Oyun Otomatik ≈ 30 Mbps, çözünürlüğe göre ölçekli). Kullanıcı kayıp görürse 40 Mbps ile bir tur daha. Yayılım kollar arası farktan büyükse sonuç "belirsiz" yazılır.
- **A2:** Normal kollarında Mac GPU kullanımı p50 ≥ 3 puan düşükse ya da Keskin'in `gpu_ms` p50'si ≥ 1 ms ise, **ve** kullanıcı oyun içi yazı/HUD'da fark görmüyorsa → Ö2. Aksi halde Keskin kalır.
- **A3:** 2240 kollarında `skip_pct` 1848'den ≤ 1 puan kötü ve çözme p95 < 16,7 ms ise ve kullanıcı fark görüyorsa → varsayılanı tartışmaya aç. Fark görmüyorsa varsayılan 1848 kalır; yalnız Ö3 (liste sadeleşmesi) kullanıcıya sorulur.
- **A4:** kalem ve dokunma koordinatları doğru, `skip_pct` makul ise "(deneysel)" etiketi kalkar; değilse 2800'ü listeden çıkarmak kullanıcıya sorulur.

## Oyun seçimi (2026-10-23)

Kullanıcı: **TotK, Mac'e yerel uygulama** (emülatör değil; emülatörler bu ölçümün kapsamı dışında). Süreç adı oturum günü uygulama açıkken okunur (`--proc`). Uygulama şu an yeniden derleniyor: oturuma kadar ona dokunulmaz (açma, kapatma, okuma yok). Dikkat edilecekler:
- TotK kendi hızını sık sık 60'ın altına indiriyor (2026-10-20: tablette <50 fps olan saniyelerin çoğunda oyun Mac'te zaten <55 fps çiziyordu). Bu yüzden kollar **aynı yerde, aynı kamera hareketiyle** alınır (ör. bir köyde dur, kumandayla kamerayı yavaşça 360° çevir), ve tablet sayıları host `cap_fps` ile birlikte okunur.
- A3'te (1848 ↔ 2240) oyunun çizim yükünün değişip değişmediği, oyunun çizim çözünürlüğünü ekrana mı yoksa kendi ayarına mı bağladığına göre değişir; oturumda oyun ayarına bakılır ve sonuçla birlikte yazılır.

## Açık

- Öneriler kod değil; karar eki (0014/0029/0030) ve kartlar ölçümden sonra yazılır.
- 120 fps için ölçekleme (Ö1) ayrıca düşünülmeli: kareler arası benzerlik arttığı için bit hızı fps ile doğrusal artmaz. [Çıkarım.]

## Sonuçlar (2026-10-23 öğlen, cihaz oturumu)

Kurulum: TotK (Mac'e yerel, `totk-native`), Oyun 60, Wi-Fi (Mac Ethernet), host `67553f99`, APK versionCode 424606, aynı köy noktası, kumandayla yavaş kamera çevirme; kol başına 100 sn, `tools/measure/game-ab.sh`. Her kolda `arm_check: ok` (bit hızı ve renk loglardan doğrulandı; ekran boyutu host `display=` satırından). Veri repo dışında (`~/.cache/matebridge-tools/data/2026-10-23-gameab/`). Tablo değerleri kol ortancası (min–maks).

**Genel:** Mac GPU her kolda %94–95 (TotK GPU'yu dolduruyor); TotK ~%130–137 CPU; MateBridgeApp %7–10, WindowServer %9–12, VTEncoder ~%2–3. MateBridge'in Mac payı her ayarda küçük kaldı.

### A1 bit hızı (1848, Normal renk, 3+3 kol)

| | 60 Mbps | 30 Mbps |
|---|---|---|
| >150 ms takılma | 0 (0–0) | 0 (0–0) |
| yeniden gönderimli saniye | %5,0 (3,4–6,7) | %9,2 (6,7–11,8) |
| `skip_pct` | 0,0 (0–6,7) | 8,4 (0–21,9) |
| çözme p50 | 10,8 ms | 9,4 ms |
| `cap_dec` p95 / p99 | 14,4 / 15,1 ms | 16,9 / 121 ms |
| Mac GPU | %95 | %94,5 |

Karar kuralı: 30 Mbps yeniden gönderimde 60'tan kötü → **Ö1 geçmedi.** Bugün WLAN sağlıklıydı (60 Mbps'te takılma yok); 2026-10-08/20'deki sorun WLAN'ın kötü olduğu anlara ait ve o durum bu oturumda yoktu. Ö1 "kötü gün" verisi olmadan yeniden açılmaz; o yöndeki karşılık `MATEBRIDGE_WIFI_ADAPT` (0023 eki, kapalı) ya da kullanıcının elle seçimi.

### A2 renk (60 Mbps, 1848, 1+1 kol — kullanıcı isteğiyle kısaltıldı)

| | Keskin | Normal |
|---|---|---|
| `gpu_ms` p50 / p95 | 0,5 / 0,6 ms | 0 |
| Mac GPU | %94 | %94 |
| MateBridgeApp CPU | %10,1 | %8,6 |

Karar kuralı: GPU farkı < 3 puan ve `gpu_ms` < 1 ms → **Ö2 geçmedi; Keskin oyunda da kalabilir.** 2800'deki 2,5–4 ms geçiş maliyeti 1848'de ~0,5 ms. Tek çift olmasına rağmen sinyal eşiğin çok altında. Renk tercihi görsel.

### A3 çözünürlük (Performans artışı açık, 60 Mbps, Normal, 2+2 kol — kullanıcı isteğiyle kısaltıldı)

| | 1848×1214 | 2240×1472 |
|---|---|---|
| `skip_pct` | 0,8 (0–1,6) | 6,4 (1,1–11,7) |
| çözme p50 / p95 | 11,1 / 11,4 ms | 12,7 / **20,5 (13,1–27,8)** ms |
| `cap_dec` p50 / p95 / p99 | 14,2 / 19,4 / 24,7 ms | 18,1 / 35,0 / 171 ms |
| >150 ms takılma | 0,5 (0–1) | 1,5 (1–2) |
| yeniden gönderimli saniye | %13,9 (7,4–20,3) | %41 (10,7–71,3) |
| kodlama p50 | 4,3 ms | 5,3 ms |
| Mac GPU / TotK CPU | %95 / %130 | %94 / %132 |

Kullanıcı: "2240'ta iyileşme var" (görsel). Karar kuralı: `skip_pct` 1848'den > 1 puan kötü ve çözme p95 > 16,7 ms → **varsayılan 1848 kalır.** 2240 seçenek olarak kalır (görüntü daha iyi; bedeli kare atlaması ve ara sıra gecikme sıçraması). Mac yükü iki boyutta aynı (TotK GPU'yu her durumda dolduruyor).

### Yan gözlemler

- Host `cap_to_sent` aynı ayarda zamanla 4,7 → 12 ms oynadı (A1 60 Mbps kolları ile A2 Normal kolu). Bu yüzden 30 Mbps (10,8) ve Keskin (18,2) kollarındaki artışlar bu kaymanın içinde; ayara bağlanmadı. GPU %94–95 doluyken yakalama/kodlama sırası beklemesi olası [çıkarım]; ayrı bakılabilir.
- A3'teki yeniden gönderim artışı (2240'ta %41) aynı bit hızında; büyük karelerin daha patlamalı gitmesi ya da WLAN'ın o dakikalarda kötüleşmesi olabilir (A3 1848 kolları da A1'den yüksek, %13,9) [çıkarım].
- Tablet decode p95 loglamıyor; değerler host'un 1 Hz `decode_ms` örneklerinden.

### Sonuç

Üç önerinin hiçbiri bugünkü veriyle geçmedi: bugünkü varsayılanlar (60 Mbps, Keskin, 1848) yerinde. Kalan tek öneri Ö3'ün sadeleştirme kısmı (2100×1380'i listeden çıkarmak) ve 2800'ün doğrulanması; ikisi de kullanıcı kararı. Oyunda Mac yükünü belirleyen MateBridge değil oyunun kendisi.
