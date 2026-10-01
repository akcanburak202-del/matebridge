---
id: T-098
title: Tablet — ses: sessizlik aralarını alt taşma saymamak, ses başlangıcında hızlı çalma, AudioTrack tamponu 1920 → 960
status: in_progress
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

- [ ] **Sessizlik ayrımı.**
  - Tampon boşaldığında yeni paket gelmiyorsa ve son paketten beri ≥ ~2 paket süresi (20 ms) geçtiyse durum "kaynak sessiz" (`idle`) sayılır: sönüşle sessizlik yazılır, `underruns` ve güvenlik payı **artmaz**. Ayrı sayaç `idle_gaps`.
  - Gerçek alt taşma (paketler akarken tamponun bitmesi) bugünkü gibi sayılır.
  - Sessizlikten sonra ilk paket: kısa açılışla (≤ 5 ms) **hedef seviye** kadar dolunca hemen çalar. Uzun hazırlık yok; A/V hedefi PRIMING kuralıyla uyumlu kalır.
  - `sample_index` sıçraması (host IO durup yeniden başlayınca) sessizlik olarak işlenir. Eski boşluk sessizlikle doldurulup gecikme biriktirilmez: büyük sıçramada tampon sıfırlanır ve yeni noktadan başlanır.
- [ ] **Tampon boyu.**
  - Başlangıç `setBufferSizeInFrames(1 × burst)` (960). Gerçek track alt taşmasında bugünkü gibi bir burst büyür (en çok 6).
  - Deney anahtarı `--ei audio_buf_bursts N` (1–6, varsayılan 1); açılışta log'a yazılır.
- [ ] Log `MB/audio` stats'a `idle_gaps` eklenir. Diğer alanlar korunur.
- [ ] Testler:
  - Kesik kesik ses simülasyonu (100 ms ses, 500 ms sessizlik, tekrar): `underruns` ve `safety_ms` artmaz, her ses başlangıcında çalma gecikmesi hedef + açılış süresinden fazla değil.
  - Gerçek ağ kesintisi simülasyonu: `underruns` artar.
  - `sample_index` sıçraması.
- [ ] `./scripts/check.sh` geçiyor. adb kullanılmaz.

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

