---
id: T-080
title: Tablet — sabit oynatma gecikmeli zamanlayıcı (düzensiz içerikte 120 Hz boşluklarını azalt), anahtar arkasında
status: done
phase: 5
owner: android-client-dev
depends_on: [T-071, T-077]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/
  - tools/pacing/
  - backlog/tasks/T-080-client-constant-playout-pacer.md
---

## Amaç

İz analizi (NOTES 2026-10-01 ~14:45). 60 Hz'te bugünkü faz kilidi kusursuz (trace6/trace8: planlanan boşluk %0,02–0,04, hazır→slot 13–16 ms). Ama **120 Hz + düzensiz içerik** (kullanıcı çiziyor, Mac pencereyi fare olay hızında ~110–117/sn günceller; yakalamalar düzenli 8,33 ms değil) — trace7, Akıcı mod: kilit %2,4 planlanan boşluk @ 13,1 ms; geç sayılan karelerin payı p90 **+60 ms** (kilit tahmini kayıyor, kareler "çok erken" diye atılıyor). Simülasyon (`tools/pacing/sim.py`, aynı iz) **sabit oynatma gecikmesi** politikasıyla: q=0,9 → 13,3 ms / %1,1; q=0,95 → 18,1 ms / %0,5; q=0,99 → 20,4 ms / %0,2.

Politika (sim.py ile birebir): x = ready − capture; taban b = son 256 karenin min(x)'i; J = (x − b)'nin q yüzdeliği; C = b + J, **2 ms histerezis** (yeni değer eskisinden > 2 ms farklıysa güncellenir); hedef t = capture + C + L (L = etkin son an, 6 ms); slot = ızgarada t'den sonraki ilk vsync, ama ready + L'den önce olamaz. Aynı slota düşen iki kare: yenisi kazanır (T-065 releaser değişmezi korunur: en yeni kare her zaman gösterilir). "Çok erken" diye atma **yok**.

## Kabul kriterleri

- [ ] `--es pacer cpd` (sabit oynatma) | `lock` (bugünkü, varsayılan); `--ei cpd_q_permille N` (varsayılan 950), `--ei cpd_hold_us N` (varsayılan 2000). `ev=display_timing` satırında etkin değerler.
- [ ] CPD yolu her panel hızında çalışır (60/120), epoch değişiminde sıfırlanır, uzun boşluktan sonra (> 1 s) C korunur ama taban penceresi yeniden dolar (gerekçelendir). Seyrek kareler (T-065 testleri) CPD'de de kayıpsız.
- [ ] **Çevrimdışı eşdeğerlik testi:** `tools/pacing/trace7_120hz_excerpt.csv` (3000 kare, yalnız zaman sütunları) test kaynağına kopyalanır/okunur; Kotlin CPD uygulaması bu izi oynatınca planlanan boşluk ve gecikme p50, `sim.py`'nin aynı parametrelerle verdiği değerlere ±0,2 puan / ±0,5 ms içinde eşit. Sim değerlerini karta yaz.
- [ ] İz (`pace_trace`) CPD kararlarını da yazar (`path=cpd`).
- [ ] `./scripts/check.sh` geçiyor.

## Plan

1. **`video/ConstantPlayoutPacer.kt` (yeni, saf):** `CpdConfig(qPermille=950, holdNs=2 ms)`; çekirdek `scheduleOn(grid, captureUs, readyNs, leadNs)` sim.py ile birebir: son 256 karenin x = ready − capture halkası, b = min, J = sıralı (x − b)[min(n−1, n·q/1000)] (tamsayı; sim'in `int(n*q)`'su ile izde aynı), C = b + J, |Cn − C| > hold ise güncelle; t = capture + C + L (L = grid.deadlineNs), slot = ızgarada max(t, ready + L)'den sonraki ilk vsync; slot ≤ önceki ise önceki slot (collided, yenisi kazanır, `lateDrop` hiç yok). Önbellek dizileri ön-ayrılmış (kare başına tahsis yok). Güvenlik: J en çok 100 ms (izde en çok ~55 ms, bağlamaz).
2. **Epoch değişimi:** her şey sıfırlanır (pencere, C, önceki slot). **> 1 s boşluk:** pencere temizlenir, C korunur; pencere `REFILL_MIN` (32) örneğe dolana kadar C yalnız yükselir (> hold). Gerekçe: pencere sayı tabanlı; seyrek güncellemede dakikalar öncesine uzanır ve x içindeki host/tablet saat farkı yavaşça kayar → taban yeniden ölçülmeli; ama az örnekle yüzdelik kuyruğu görmez, C'yi düşürmek ilk sürekli karelerde boşluk yaratır, yükseltmek güvenli. Boşluk eşiği yapılandırılabilir (test için kapatılabilir).
3. **İz:** `PaceProbe.PATH_CPD` → `path=cpd`; sütun eşlemesi Handoff'ta.
4. **Bağlantı:** `VideoRenderer.cpdConfig` (null = `lock`); adaptif modda CPD seçiliyse `AdaptivePacer` yerine çağrılır. `MainActivity`: `--es pacer cpd|lock`, `--ei cpd_q_permille`, `--ei cpd_hold_us`; `ev=display_timing`'e `pacer cpd_q_permille cpd_hold_us`.
5. **`tools/pacing/sim.py`:** `--hz 120` (periyot süzgeci + süreklilik), `--idle-ms/--refill` (aynı boşluk kuralı), `--q/--L/--hold` tek koşu; varsayılan çıktı değişmez.
6. **Testler:** iz eşdeğerliği (izi yerinde okur, `../../tools/pacing/`): boşluk kuralı kapalıyken orijinal sim değerleri, açıkken genişletilmiş sim değerleri (±0,2 puan / ±0,5 ms); T-065 seyrek kare senaryoları CPD + SlotReleaser ile (60/120 panel, 60/120 akış, panel geçişi); epoch sıfırlama, boşluk sonrası C korunması, hold, çarpışmada yenisi kazanır.

## Handoff

- **Commit:** `6167be8` (kod), plan `98ffdc2`; dal `task/T-080-client-cpd-pacer`. `./scripts/check.sh` ALL OK.
- **Dokunulan dosyalar:** `video/ConstantPlayoutPacer.kt` (yeni: `CpdConfig`, `ConstantPlayoutPacer`), `video/VideoRenderer.kt` (`cpdConfig`, adaptif modda CPD seçimi, `paceDUs`), `video/PaceTrace.kt` (`PATH_CPD`, `path=cpd`), `MainActivity.kt` (anahtarlar + `ev=display_timing`), `test/.../video/ConstantPlayoutPacerTest.kt` (yeni, 11 test), `tools/pacing/sim.py` (`--hz`, `--idle-ms/--refill`, `--q/--L/--hold`; varsayılan 60 Hz tablosu aynı), `tools/pacing/README.md`, bu kart.
- **Sim değerleri (`trace7_120hz_excerpt.csv`, 2868 kare, sürekli 2728; L = 6 ms, hold 2 ms) ve Kotlin sonucu — birebir aynı (sayılar dahil):**

  | q | sim.py (boşluk kuralı yok) | Kotlin | sim.py `--idle-ms 1000` | Kotlin (varsayılan, boşluk kuralı açık) |
  |---|---|---|---|---|
  | 0,90 | 13,2816 ms / %1,0630 (29) | aynı | 12,9593 ms / %1,0630 (29) | aynı |
  | **0,95** | **18,0738 ms / %0,4765 (13)** | aynı | **15,6266 ms / %0,4765 (13)** | aynı |
  | 0,99 | 20,3970 ms / %0,1833 (5) | aynı | 19,7933 ms / %0,2199 (6) | aynı |

  Komut: `python3 tools/pacing/sim.py tools/pacing/trace7_120hz_excerpt.csv --hz 120 --q 0.95 [--idle-ms 1000]`. İzde 3 tane > 1 s boşluk var (22 s, 1,2 s, 2,1 s); boşluk kuralı aynı boşluklarla gecikmeyi ~2,4 ms düşürüyor (eski pencere boşluk sonrası karelere taşınmıyor), boşluk oranı aynı. Test her iki modu da ±0,2 puan / ±0,5 ms ile kontrol ediyor.
- **Varsayımlar:**
  - Politika sim.py ile birebir: pencere 256 kare (sayı tabanlı), yüzdelik indeksi `min(n−1, n·q‰/1000)` (tamsayı; izde `int(n*q)` ile aynı sonuç), hold kesin `>`, L = `grid.deadlineNs` (T-071 etkin son an, 120 Hz'te 6 ms), slot = ızgarada `max(capture + C + L, ready + L)`'den sonraki ilk vsync (`gridSlotAtOrAfter`). Slot ≤ önceki ise `slotNs = önceki`, `collided`, `lastSlot` değişmez (sim'deki "dropped"); `lateDrop` hiç üretilmez. Kayıp yok: SlotReleaser (T-065) bekleyeni değiştirir ya da bırakılmış slotun ardına taşır.
  - **> 1 s boşluk (hazır zamanına göre, AdaptivePacer ile aynı eşik):** pencere temizlenir, C ve önceki slot korunur; pencere 32 örneğe dolana kadar C yalnız yükselir (> hold). Gerekçe: pencere sayı tabanlı, seyrek güncellemede dakikalar öncesine uzanır; x içindeki host/tablet saat farkı yavaşça kayar (taban yeniden ölçülmeli) ve boşta CPU/çözücü durumu değişir. Az örnekle yüzdelik kuyruğu göremez → C'yi düşürmek sonraki sürekli patlamanın ilk karelerini geç bırakır; yükseltmek güvenli. 32 ≥ 1/(1−0,95) = 20.
  - Epoch değişimi: pencere, C, önceki slot sıfırlanır.
  - Güvenlik: J ≤ 100 ms (izde en çok ~55 ms; bağlamaz). C ile gecikme sınırsız değil: kalıcı jitter 50 ms ise gecikme ~50 ms + L olur (politikanın doğası).
  - İz `path=cpd` satırlarında sütun anlamları: `dev_ns` = x − b, `d_ns` = C − b, `jitter_ns` = J (hold öncesi), `earliest_ns` = ızgarada ready + L, `acquire_ns` = hedef t = capture + C + L (ızgaraya yuvarlanmamış), `lock_slot_ns` = C (ready − capture alanı, saat farkı dahil), `k` = penceredeki örnek sayısı, `bad_run` = 1 bu karede C değiştiyse. `late_drop` hep 0; `collided` = önceki slotu paylaştı. Sütun adları değişmedi (araçlar bozulmasın).
  - `ev=present` satırı: `phase_lock=0`, `rephase=0`, `d_us` = C − b. `onSkipWindow` geri beslemesi (AdaptivePacer seviyesi) CPD'yi etkilemez. Yalnız MediaCodec adaptif yolunda (`jitter` ekstrası yok, GL değil); `pacer=cpd` + `--ei jitter N` ya da `--es render gl` ise faz kilidi/eski yol kullanılır ve log `pacer=lock` der.
- **Test edilmeyenler / cihazda doğrulanacaklar:** cihaza dokunulmadı.
  1. Başlat: `adb shell am start -n dev.matebridge.client/.MainActivity --es pacer cpd --ez pace_trace true` (ayar: `--ei cpd_q_permille 990 --ei cpd_hold_us 2000`). Log: `MB/render ev=display_timing ... pacer=cpd cpd_q_permille=950 cpd_hold_us=2000`; ekstrasız `pacer=lock`.
  2. 120 Hz, kalemle çizim (trace7 koşulları): SF `--latency` 16,7 ms tekrar oranı ve iz (`adb exec-out run-as dev.matebridge.client cat cache/pace_trace.csv > trace.csv`): `path=cpd`, planlanan boşluk ~%0,5, hazır→slot p50 ~15–18 ms; aynı oturumda `lock` ile A/B.
  3. **Risk:** CPD slotları hazır anından ~C + L ileride; SlotReleaser beklemeyi `slot − 7 ms`'de bırakır, yani codec'e birkaç kare ileri zaman damgasıyla verilebilir (J büyükse 120 Hz'te ~5–6 kare BufferQueue'da). Kare düşmesi/çıkış arabelleği tükenmesi (`in_codec_p95`, `slot_dups`, keyframe istekleri) izlenmeli.
  4. 60 Hz boşta/yazarken: donma yok (T-065), seyrek kare sonrası görüntü güncel; 120↔60 geçişinde akış sürüyor.
  5. Gecikme: kalem → ekran algısı; `d_us` (C − b) çizim sırasında ~10–20 ms bekleniyor.
- **Açık sorular:** (a) Boşluk kuralı izde gecikmeyi düşürdü ama 32 örnek eşiği cihazda ölçülmedi. (b) Sürekli 60/60 akışta CPD faz kilidinden daha mı iyi, bilinmiyor (izi yok); varsayılan `lock` kaldı. (c) `ev=present` satırına `pacer` alanı eklemek `StatsFormat.kt` gerektirir (kart dışı); şimdilik yalnız `display_timing`.

## Orkestratör notu (2026-10-01): A/B sonucu

SF: lock %1,54 çift @ 11,2 ms; cpd %0,57 çift @ 17,0 ms. Kullanıcı cpd'de gecikmeyi hissetti → varsayılan `lock`; cpd deney anahtarı olarak kalır.
