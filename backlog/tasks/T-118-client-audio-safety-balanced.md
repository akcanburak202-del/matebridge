---
id: T-118
title: Tablet — ses güvenlik payı "dengeli" politika (hızlı küçülme, hatırlanan değer en çok 30 ms, alt taşma sonrası aşırı dolumu kısalt)
status: done
phase: 5
owner: android-client-dev
depends_on: [T-117]
decisions: [0011, 0012]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/audio/
  - client-android/app/src/test/
  - backlog/tasks/T-118-client-audio-safety-balanced.md
---

## Amaç

NOTES 2026-10-02 ~10:10 (T-116/T-117 cihaz ölçümü, USB):
- Aktarım neredeyse temiz: 6,5 dakikada 1 alt taşma. O anda paket aktarımda ~40 ms tutuldu.
- Ama ses ~80 ms, görüntü ~36 ms; `av_offset_ms` ~44.
- Asıl maliyet hatırlanan güvenlik payı: `safety_ms` 35–40.
  - T-108 politikası: alt taşma başına +5 ms (tavan 40). Küçülme yalnız çalarken, 60 temiz pencerede −1 ms; 40 → 20 ≈ 20 dk sürekli ses. Değer saklanıyor.
  - Alt taşmadan sonra yeniden dolum hedefi `target + lastSpan`; seviye 75 ms'ye, `audio_ms` 113'e çıkıyor ve PI (en çok 5 ms/s) >10 s'de geri getiriyor.

**Kullanıcı kararı (2026-10-02):** "Dengeli". Pay temiz geçen sürede saniyeler ölçeğinde küçülsün, hatırlanan değer en çok ~30 ms olsun. Hedef ses ~60–65 ms. Nadir takılmada çok kısa, yumuşatılmış (T-108 fade) bir kesinti kabul.

## Kapsam dışı

- Aktarım tarafı (adb tüneli / Wi-Fi): ayrı araştırma.
- AAudio çıkış arabelleği boyu (T-114, 4 burst).
- Videoyu sese göre geciktirmek (yapılmayacak: girdi gecikmesi).
- AudioTrack ("Uyumlu") yolunun tabanı: aynı kurallar uygulanabilir, ayrı ayar gerekmez; Plan'da belirt.

## Kabul kriterleri

- [x] **Hatırlanan değer tavanı:** `SafetyMemory` en çok 30 ms saklar ya da başlatır (`REMEMBER_MAX_MS = 30`). Eski 40'lık kayıt açılışta 30 olarak okunur. Oturum içi tavan 40 kalır.
- [x] **Hızlı küçülme:** temiz pencerede (alt taşma yok) pay saniyeler ölçeğinde tabana iner. Hedef: 40 → 20 en çok ~2 dk temiz çalma (örneğin her 5 temiz pencerede −1 ms). Plan'da gerekçe ve seçilen sayı yazılır. Alt taşma adımı +5 ms kalır.
- [x] **Alt taşma sonrası dolum:** yeniden dolum seviyesi `audio_ms`'i kalıcı şişirmez.
  - Alt taşmadan sonra en geç ~3 s içinde seviye yeni hedefin ±5 ms'ine döner.
  - Ya dolum hedefinden `lastSpan` payı kaldırılır ya da sınırlandırılır, ya da hedefin üstündeki fazla hızlı ama duyulmaz biçimde boşaltılır.
  - Perde (pitch) sapması ≤ %0,5 kalır; daha hızlı boşaltma gerekiyorsa sessiz anlarda kare atlama gibi duyulmaz bir yol Plan'da gerekçelendirilir.
- [x] Log: ses `ev=stats` satırında mevcut `safety_ms` yeterli. Açılışta saklanan → kullanılan değer bir kez loglanır (`safety_start stored= used=`).
- [x] Birim testleri:
  - (a) saklı 40 → açılış 30;
  - (b) temiz akışta 40 → 20 süresi kabul aralığında;
  - (c) tek alt taşma +5 ve sonra tekrar küçülme;
  - (d) alt taşma sonrası seviye ≤ 3 s'de hedefe döner;
  - (e) mevcut T-108/T-110/T-114 testleri geçer ya da gerekçeyle güncellenir.
- [x] `./scripts/check.sh` geçiyor. Cihaz testi orkestratörde.

## Plan

1. **Hatırlanan tavan (`SafetyMemory`)**: `REMEMBER_MAX_MS = 30`. `initial()` saklı değeri `SAFETY_MIN..30` aralığına kırpar (eski 40 → 30). `onSafety`/`flush` saklamadan önce değeri 30'a kırpar ve karşılaştırmayı kırpılmış değerle yapar; oturum içi 35–40 her 10 s'de bir yazmaya yol açmaz. Oturum içi tavan (`DriftController.SAFETY_MAX_MS = 40`) değişmez.
2. **Hızlı küçülme (`DriftController`)**: `DECAY_WINDOWS` 60 → **5** (her 5 temiz 1 s pencerede −1 ms). 40 → 20 = 20 adım × 5 s = **100 s** (kabul: ≤ ~2 dk). Bir alt taşmanın +5'i 25 s'de geri alınır. Böylece nadir takılmada (USB'de ~6,5 dk'da bir) pay çoğu zaman tabanda (AAudio 20 ms) kalır; kullanıcının seçtiği "dengeli" denge budur. Daha hızlısı (ör. 3 pencere, 60 s) aynı gecikmeyi kazanmaz, yalnız ardışık takılma riskini artırır. Alt taşma adımı +5 ms kalır.
3. **Alt taşma sonrası dolum (`PlayoutCore` + `DriftController`)**:
   - Kök neden: aktarımda tutulan paketler topluca geliyor. Seviye eşiği (`target + lastSpan`) bir sıçramada aşıp ~75 ms'ye çıkıyor. Ayrıca `lastSpan`, takılmanın iniş eğimini içeren pencereden şişmiş olabiliyor.
   - (a) `refillThresholdFrames` içindeki aralık payı `REFILL_SPAN_MAX_MS = 20` (iki paket) ile sınırlanır. Normal testere ~10–15 ms; tavan bunu etkilemez, yalnız şişmiş pencereyi keser.
   - (b) **Başlangıçta fazlayı atma**: PRIMING → PLAYING geçişinde seviye eşik + `TRIM_SLACK_MS` (5 ms) üstündeyse, en eski kareler eşiğe kadar atılır (`buffer.consume`). Alt taşma henüz sınıflanmadıysa (`starvePending`), beklenen +5 ms adım bırakılır. Ardından mevcut 5 ms fade-in başlar.
   - Duyulmazlık gerekçesi: atma, zaten sessiz olan çıkışta (fade-out + sessizlik) ve fade-in'den önce yapılıyor. Duyulan şey, kesintinin süresi değil içeriğinden birkaç on ms eksik olması; tıklama yok, perde değişmiyor.
   - Atma yapılmayan durumlar: A/V bekletmesiyle (hold) başlangıç, çünkü orada fazla bilinçli ve A/V tabanı olur; sessizlik sonrası hızlı yeniden başlama (`quickRestart`), çünkü yeni sesin başı kesilmesin. *(Uygulamada düzeltildi: 20 ms'den uzun takılma da `quickRestart` yolundan geçiyor. Bu yüzden ölçüt, kuruma "idle" sınıflandırılmış olmasıdır (`idleRestart`). Takılmanın topluca gelen paketleri yakalama atlamasız olduğu için zaten alt taşma olarak onaylanıyor ve kırpılıyor.)*
   - PI sınırları değişmez (≤ %0,5 perde). Taban ilk pencerede hedefe oturur, PI yalnız küçük kalıntıyı düzeltir.
   - Sayaçlar: `refill_trims`, `refill_trim_ms` ses `ev=stats` satırına eklenir (cihaz doğrulaması için).
4. **Log**: çıkış açılırken (`applySafety` yeni API ile çağrıldığında) bir kez `ev=safety_start api= stored= used= source=`.
5. **AudioTrack ("Uyumlu") yolu**: aynı `DriftController`/`PlayoutCore`/`SafetyMemory` kurallarını kullanır; tabanı 5 ms kalır, ayrı ayar yok.
6. **Testler**:
   - `SafetyMemoryTest`: (a) saklı 40 → 30; kayıt 30'a kırpılır.
   - `DriftControllerTest`: (b) 40 → 20 temiz akışta 100 pencere; (c) +5 sonra 25 pencerede geri; eşik aralık tavanı.
   - Yeni `UnderrunRefillTest`: (d) simülasyonda topluca gelen 80 ms takılma → alt taşma, ≤ 3 s'de taban hedefin ±5 ms'inde, perde ≤ %0,5.
   - (e) Mevcut testler, yavaş küçülmeye bağlı beklentiler sabit adıyla güncellenir.

## Handoff

- **Commit:** `79a3d33` (uygulama), plan `dc0348b`; bu handoff ayrı commit. Dal: `task/T-118-audio-safety-balanced`.
- **Dokunulan dosyalar:**
  - `audio/SafetyMemory.kt`: `REMEMBER_MAX_MS = 30`, `rememberable()`; okuma ve yazma 30'a kırpılır.
  - `audio/DriftController.kt`: `DECAY_WINDOWS` 60 → 5; `REFILL_SPAN_MAX_MS = 20` ve `refillSpanFrames`; `safetyStepFrames`.
  - `audio/PlayoutCore.kt`: başlangıçta kırpma (`trimExcess`, `TRIM_SLACK_MS = 5`, `idleRestart`, `refillTrims`/`refillTrimFrames`).
  - `audio/AudioPlayout.kt`: `ev=safety_start` logu; stats satırına `refill_trims=` ve `refill_trim_ms=`.
  - Testler: `SafetyMemoryTest`, `DriftControllerTest`, `PlayoutSimulationTest` (resync testi artık fazlayı oynatma başladıktan sonra veriyor; başlangıçtaki fazla kırpılıyor), yeni `UnderrunRefillTest`.
- **Varsayımlar:**
  - Takılmada tutulan paketler topluca ve yakalama zamanında atlama olmadan geliyor (NOTES 10:10). Bu yüzden alt taşma, oynatma başlamadan onaylanıyor (≥3 paket) ve eşik yeni (+5) hedefle hesaplanıyor.
  - Normal testere aralığı ≤ 20 ms. Wi-Fi'de daha genişse, alt taşma sonrası taban hedefin biraz altına başlar ve PI düzeltir.
  - Kırpma sessiz çıkışta, fade-in'den önce yapılıyor. Duyulan şey zaten var olan kesinti; ek tık ya da perde değişimi yok.
  - Simülasyonda (80 ms takılma, 35 ms öğrenilmiş pay) kırpma olmadan 3 s sonra taban hatası ~27 ms. Kırpmayla ±5 ms içinde (test kırpma kapatılarak doğrulandı).
  - AudioTrack yolu aynı kuralları kullanıyor (taban 5 ms); ayrı ayar yok.
- **Test edilmeyenler / cihazda doğrulanacaklar:**
  1. Açılışta `ev=safety_start api=aaudio stored=30 used=30` görünmeli (cihazdaki eski 40 kaydı 30 okunur).
  2. Temiz çalmada `safety_ms` her ~5 s'de 1 düşmeli; 30 → 20 yaklaşık 50 s. Hedef `audio_ms` ~60–65, `av_offset_ms` belirgin biçimde düşük (önceki ~44).
  3. Alt taşmada `underruns` +1, `safety_ms` +5, `refill_trims` +1. `level_ms_floor` 1–3 stats saniyesinde `target_ms` ±5'e dönmeli; `audio_ms` 113'e sıçramamalı.
  4. Kulakla: takılmada kısa, yumuşak bir kesinti olmalı; tık, perde kayması ya da hızlanma duyulmamalı. Sessizlikten sonra yeni sesin başı kesilmemeli (`idle_gaps` artarken `refill_trims` artmamalı).
  5. Alt taşma sıklığı: pay 20'ye inince USB'de alt taşma sayısının kabul edilebilir kalıp kalmadığı (~6,5 dk'da bir mi, daha sık mı).
- **Açık sorular:**
  - `docs/LOGGING.md` kartın `files:` listesinde değil; yeni `ev=safety_start` olayı ve `refill_trims`/`refill_trim_ms` alanları orkestratör tarafından eklenebilir.
  - Hızlı yeniden başlama koşulu (`level + sinceLast >= target + lastSpan`) hâlâ sınırsız `lastSpan` kullanıyor; kırpma eşiği ise sınırlı aralığı kullanıyor. Bilinçli olarak dokunulmadı (kapsam).
