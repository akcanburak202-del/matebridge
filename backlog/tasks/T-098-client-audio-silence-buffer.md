---
id: T-098
title: Tablet — ses: sessizlik aralarını alt taşma saymamak, ses başlangıcında hızlı çalma, AudioTrack tamponu 1920 → 960
status: done
phase: 5
owner: android-client-dev
depends_on: [T-095]
decisions: [0011]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/audio/
  - client-android/app/src/test/kotlin/dev/matebridge/client/audio/
  - backlog/tasks/T-098-client-audio-silence-buffer.md
---

## Amaç

T-097'nin ilk iki maddesi. NOTES 2026-10-01 ~20:50:
- Ses ~170–190 ms, video ~51 ms.
- Host'ta Mac ses çalmazken tap IO'su duruyor; o aralıkta `AUDIO_FRAME` gelmiyor. Tablet bunu alt taşma sayıyor (`underruns` 2–3), `safety_ms` 5 → 20 büyüyor ve sonraki seslerde gecikme artıyor.
- AudioTrack `buf_frames=1920` (2 × 960 burst); çıkış HAL'i 960 kare (20 ms), `perf_mode=none`.

Kullanıcı gecikmeyi göze batan bulmadı. Amaç, düşük riskli kazançlar.

## Kabul kriterleri

- [x] **Sessizlik ayrımı.**
  - Tampon boşaldığında yeni paket gelmiyorsa ve son paketten beri ≥ ~2 paket süresi (20 ms) geçtiyse durum "kaynak sessiz" (`idle`) sayılır: sönüşle sessizlik yazılır, `underruns` ve güvenlik payı **artmaz**. Ayrı sayaç `idle_gaps`.
  - Gerçek alt taşma (paketler akarken tamponun bitmesi) bugünkü gibi sayılır.
  - Sessizlikten sonra ilk paket: kısa açılışla (≤ 5 ms) **hedef seviye** kadar dolunca hemen çalar. Uzun hazırlık yok; A/V hedefi PRIMING kuralıyla uyumlu kalır.
  - `sample_index` sıçraması (host IO durup yeniden başlayınca) sessizlik olarak işlenir. Eski boşluk sessizlikle doldurulup gecikme biriktirilmez: büyük sıçramada tampon sıfırlanır ve yeni noktadan başlanır.
- [x] **Tampon boyu.**
  - Başlangıç `setBufferSizeInFrames(1 × burst)` (960). Gerçek track alt taşmasında bugünkü gibi bir burst büyür (en çok 6).
  - Deney anahtarı `--ei audio_buf_bursts N` (1–6, varsayılan 1); açılışta log'a yazılır.
- [x] Log `MB/audio` stats'a `idle_gaps` eklenir. Diğer alanlar korunur.
- [x] Testler:
  - Kesik kesik ses simülasyonu (100 ms ses, 500 ms sessizlik, tekrar): `underruns` ve `safety_ms` artmaz, her ses başlangıcında çalma gecikmesi hedef + açılış süresinden fazla değil.
  - Gerçek ağ kesintisi simülasyonu: `underruns` artar.
  - `sample_index` sıçraması.
- [x] `./scripts/check.sh` geçiyor. adb kullanılmaz.

## Plan

**Ayrım ölçütü.** Kartın "son paketten beri ≥ 20 ms" kuralı tek başına ağ kesintisini de `idle` sayar (kesintide de paket gelmez), oysa kabul testi ağ kesintisinde `underruns` artmasını istiyor. Bu yüzden karar paketin **host yakalama zamanına** bakılarak verilir:
- Ağ kesintisi (≤ 100 ms) ya da titreşim: host yakalamaya devam eder, paketler geç ama `capture_time_us` sürekli gelir → gerçek alt taşma.
- Kaynak sessiz (tap IO durdu): yeniden gelen paketlerde `capture_time_us` (ve/veya `sample_index`) ileri sıçrar → `idle`.
- Host IO dururken yarım kalan paket yeniden başlayınca eski zamanla tamamlanıyor (`AudioPacketizer`), sıçrama bu yüzden ikinci pakette görünebilir. Karar bu yüzden ertelenir.

**`AudioJitterBuffer`:**
- `packets` sayacı (yazılan paket) ve `discontinuities` sayacı. Süreksizlik: `capture_time_us` beklenenden (önceki paket + süresi) ≥ 20 ms ileride ya da `sample_index` sıçraması > 20 ms.
- `sample_index` boşluğu ≤ 20 ms (host bir iki paket atmış): bugünkü gibi sönüş + sessizlik + açılış (zamanlama korunur).
- Daha büyük sıçrama (`jumps` sayacı): sessizlikle **doldurulmaz**, akış konumu yeni noktadan başlar. Okunmamış kuyruk (gerçek ses) sönüşle kalır, yeni paket açılışla eklenir; gecikme birikmez. Okuyucu boşalmışsa bu, tamponun sıfırlanıp yeni noktadan başlamasıyla aynıdır. Varsayılan `maxGapFillFrames` 4800 → 960.

**`PlayoutCore`:**
- Her burst'te `buffer.packets` değişti mi diye bakılır: `framesSinceLastPacket` (çıkış karesiyle ölçülür, testte deterministik).
- Tampon bitince (PLAYING → FADING_OUT) alt taşma hemen sayılmaz, `starvePending` olur (o anki `packets` ve `discontinuities` saklanır):
  - O andan sonra süreksizlik görülürse → `idleGaps++`; `underruns` ve güvenlik payı değişmez.
  - Süreksizlik olmadan 3 paket gelirse → `drift.onUnderrun()` (bugünkü gibi).
  - Hiç paket gelmezse bekler, hiçbir şey sayılmaz.
- `idle` (log için): PRIMING, daha önce çalınmış ve son paketten beri ≥ 20 ms.
- Sessizlikten sonra hızlı başlangıç: tükenmeden sonra PRIMING'de ≥ 20 ms paket gelmediyse ya da `idle` kararı verildiyse, eşik `hedef + burst + 3 ms sönüş payı` olur (çalınabilecek en küçük seviye; aralık terimi yok). Açılış 5 ms. A/V bekletmesi (`primingHoldUs`) ve A/V tabanı (hedefin parçası) aynen uygulanır.

**`AudioPlayout`:**
- `START_BURSTS` sabiti yerine `AudioBufferConfig.startBursts(...)`: `--ei audio_buf_bursts N`, 1–6 aralığına sıkıştırılır, varsayılan 1.
- `MainActivity`'ye (T-096 değiştiriyor) dokunmamak için değer, `AudioPlayout`'a verilen `Context` bir `Activity` ise onun intent'inden okunur.
- Açılışta `audio_device` satırına `buf_bursts=N` yazılır. Track alt taşmasında bugünkü gibi +1 burst, en çok 6.
- `stats` satırına `idle_gaps` ve `jumps` eklenir; sessizken `state=idle`. Diğer alanlar aynı.

**Testler:**
- `PlayoutSimulationTest`:
  - Kesik kesik ses (100 ms ses / 500 ms sessizlik, host yakalama zamanı sürekli ilerler; yarım paket durumu dahil; burst 96 ve 960): `underruns` ve `safety_ms` artmaz, `idleGaps` ses sayısı kadar. Her ses başlangıcında ilk paketten ilk sesli örneğe geçen süre ≤ hedef + açılış (+ bir burst ayrıntısı).
  - Ağ kesintisi (80 ms paket yok, sonra biriken paketler sürekli zamanla gelir): `underruns` artar.
  - `sample_index` sıçraması sessizlikten sonra: dolgu yok, seviye birikmez.
- `AudioJitterBufferTest`: büyük sıçrama dolgusuz; küçük boşluk dolgulu; süreksizlik sayacı.
- `AudioBufferConfigTest`: varsayılan, sıkıştırma.
- Var olan `stalledProducer...` testi yeni erteleme kuralına göre güncellenir (karar 3 paket sonra).

## Handoff

**Commit'ler:** plan `776425a`, uygulama `dfce55d`. Dal `task/T-098-audio-silence` (`a44ca94` üstünde).

**Dosyalar** (yalnız `client/audio/` ve testleri):
- `AudioJitterBuffer.kt`:
  - Sayaçlar: `packets`, `discontinuities`, `jumpEvents`.
  - ≤ 20 ms boşluk sessizlikle dolar; daha büyük sıçrama dolmaz, yeni noktadan devam eder.
  - `capture_time_us` sıçraması ≥ 20 ms süreksizlik sayılır.
- `PlayoutCore.kt`: ertelenmiş tükenme kararı (`idleGaps` / `drift.onUnderrun()`), `idle`, sessizlikten sonra hızlı başlangıç.
- `AudioPlayout.kt`:
  - Başlangıç tamponu `AudioBufferConfig` (varsayılan 1 burst).
  - `audio_device` ve `audio_track` satırlarına `buf_bursts`.
  - `stats` satırına `jumps` ve `idle_gaps`; sessizken `state=idle`.
- Yeni: `AudioBufferConfig.kt`.
- Testler:
  - Yeni: `SilenceGapSimulationTest.kt` (9 test), `AudioBufferConfigTest.kt`.
  - Güncellenen: `AudioJitterBufferTest.kt` (büyük sıçrama, küçük boşluk, süreksizlik), `PlayoutSimulationTest.kt` (`stalledProducer…` artık 3 paket sonra karar veriyor).

**`./scripts/check.sh`: ALL OK** (`dfce55d`).

**Varsayımlar / plandan sapmalar:**
- *Ayrım ölçütü host yakalama zamanı.* Kartın "son paketten beri ≥ 20 ms" kuralı ağ kesintisini de idle sayardı.
  - Tükenmeden sonra gelen paketlerde `capture_time_us` ya da `sample_index` ≥ 20 ms ileri sıçrarsa → `idle_gaps`.
  - Sıçrama olmadan 3 paket gelirse → `underruns` (+5 ms güvenlik payı, bugünkü gibi).
  - 20 ms kuralı yalnız hızlı başlangıcı ve log'daki `state=idle`'ı belirler.
- *Hızlı başlangıç eşiği.* Plandaki "hedef + burst + 3 ms" tek başına yetmedi: tek 10 ms paketle başlayınca ikinci paket gelmeden tampon bitiyordu (simülasyon). Son kural:
  - `seviye ≥ hedef + burst + 3 ms` ve `seviye + son paketten beri geçen ≥ hedef + varış aralığı`.
  - Böylece bir sonraki paket seviyeyi hedefte bulur.
  - Burst 96'da sesin ilk karesi paketten ~hedef (5 ms) sonra duyulur, test sınırı hedef + 5 ms açılış. Burst 960'ta (bu tablet) en az 1344 kare (~28 ms) gerekir; bu, burst boyunun doğal alt sınırı.
- *"Tampon sıfırlanır".* Büyük sıçramada okunmamış kuyruk gerçek sestir, atılmaz: sönüşle kalır, yeni paket açılışla hemen arkasına eklenir, sessizlik eklenmez. Okuyucu boşalmışsa bu, sıfırlayıp yeni noktadan başlamakla aynıdır.
- *Bilinen sınır.* 100 ms'den uzun ağ kesintisinde host eski paketleri atar (`sample_index` ve zaman sıçrar). Bu durum idle sayılır. Güvenlik payı oradaki kaybı zaten önleyemez.
- *`audio_buf_bursts` okuma yolu.* `MainActivity`'ye (T-096) dokunmamak için değer `AudioPlayout`'a verilen `Context`'in (Activity) intent'inden okunur. Aralık dışı değerler 1–6'ya sıkıştırılır. Track yeniden kurulunca (routing / dead object) yine başlangıç değerine döner (bugünkü gibi).
- PI penceresi her çalma başlangıcında sıfırlandığı için sessizlik sonundaki boşalma tabanı ve oranı bozmaz.

**Test edilmedi (tablet gerekli):**
- 1 burst (960) tamponla gerçek track alt taşması ve büyüme.
- Mac IO durup başlarken `sample_index` sıçrıyor mu, yoksa yarım paket mi oluşuyor? İkisi de simüle edildi.
- Gerçek gecikme kazancı.

**Tablette kontrol (orkestratör):**
1. Kur, `am start -S -n dev.matebridge.client/.MainActivity` ile başlat (ek yok). `adb logcat -s MB/audio`:
   - `ev=audio_device … buf_bursts=1` görünmeli.
   - Akış başlayınca `ev=audio_track … buf_bursts=1 buf_frames=960` görünmeli. HAL daha büyük verdiyse `buf_frames` onu gösterir; not al.
2. Mac'te kısa sesleri aralıklı çal (bildirim sesi, 1–2 sn arayla birkaç kez):
   - `stats` satırında `underruns` 0'da, `safety_ms=5` kalmalı.
   - `idle_gaps` her sessizlikte 1 artmalı; sessizken `state=idle`.
   - `jumps` artıyorsa Mac IO yeniden başlarken `sample_index` sıçratıyor demektir (bilgi için not al).
3. Müzik çal (≥ 30 sn):
   - `track_underruns` ve `audio_buffer_grow` satırlarına bak. Büyüme olduysa `buf_frames` en çok 5760'a çıkar.
   - Kesinti ya da cızırtı olmamalı.
   - `audio_ms` T-095 ölçümüne (~170–190) göre ~20 ms düşmüş olmalı.
4. Karşılaştırma: `--ei audio_buf_bursts 2` ile yeniden başlat (`-S`). Log'da `buf_bursts=2 buf_frames=1920` olmalı; `audio_ms` farkını not et.
5. Ağ kesintisi olursa (Wi-Fi'de) `underruns` artmalı, `idle_gaps` artmamalı.
