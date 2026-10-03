---
id: T-177
title: Add a live encoder bitrate setter (no restart) and verify VT honours it
status: review
phase: 6
owner: mac-host-dev
depends_on: [T-162, T-176]
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift
  - host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift
  - host-mac/Sources/MateBridgeCore/Video/EncoderKnobs.swift
  - host-mac/Sources/MateBridgeCore/Video/EncoderSubmitOrder.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/
  - docs/LOGGING.md
  - backlog/tasks/T-177-host-live-bitrate-setter.md
---

## Amaç

Today any bitrate change restarts capture and the encoder, and the client has to reconnect video and receive a fresh IDR. A restart costs exactly the keyframe burst that hurts Wi-Fi, so the restart path cannot be used as an in-session lever. This card adds a setter that changes the bitrate of the live VideoToolbox session, and checks on the real M6 encoder how fast frame sizes follow. It is the building block for a fixed Wi-Fi profile (T-178) and any later adaptation (T-196).

Source: external architecture review 2026-10-03 (H03, A6); verification: docs/reviews/2026-10-03/verify-F-network.md (F-1, additional issue A-3).

## Bağlam

**Evidence at HEAD (a30c769):**
- `AverageBitRate` and `DataRateLimits` are set only at creation (`host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift:168-184`).
- `DataRateLimits` is `[2 × average bytes, 1 s]` (`:182-184`). There is no short-window cap, so single frames of 100–450 KB are allowed (F A-3, LM7).
- With `MATEBRIDGE_QUALITY` accepted (`qualityApplied`), `AverageBitRate` is **not** set at all (`:167-181`). In that mode the setter can change only `DataRateLimits`, and the Handoff must say so.
- A live-property precedent exists: `MaxAllowedFrameQP` is changed on the running session before a submit (`updateQPBoost`, `:430-453`, T-087).
- **Caveat:** that precedent is negative. T-087 found that `.fast` silently ignores a mid-stream `MaxAllowedFrameQP` (`HEVCEncoder.swift:220-223`), and `.fast` is the default at every fps. Expect the same risk for `AverageBitRate`: `VTSessionSetProperty` can return `noErr` and still have no effect.
- Restart path today: `STREAM_PREFS` with a new bitrate → `StreamCoordinator.swift:373-389` (`applyPrefs`: new `config_id`, `STREAM_CONFIG`, video close) → `restartPipeline` (`:555-570`). PROTOCOL §0x05 requires this behaviour for **user** changes. This card does not change that path.
- Outside this repo, WebRTC's VideoToolbox encoder updates `AverageBitRate`/`DataRateLimits` mid-session, so a live update is plausible. Whether the M6 HEVC hardware encoder with `RealTime=false` (`.fast` profile, `:130-137`, `:159`) reacts quickly is unknown. Measure it; do not assume.

**Design hints:**
- Shape: `HEVCEncoder.setTargetBitrate(kbps:)` plus a pure Core value type for the rate request: clamp to `[floor, ceiling]` and deduplicate equal values. The pure type lives in `EncoderSubmitOrder.swift`, next to T-162's owner logic.
- **Ordering:** the setter must be serialised with submit, invalidate and stop through T-162's owner queue (`host-mac/Sources/MateBridgeCore/Video/EncoderSubmitOrder.swift`, created by T-162). Never call `VTSessionSetProperty` after `stop`.
- **Debug step knob** (`EncoderKnobs.swift`): steps the bitrate on a timer for the device check, e.g. `MATEBRIDGE_BITRATE_STEP=60000,15000,60000@5s`. It is default off. Per draft decision 0026, its doc comment names its closing card (T-196, or retire after T-127). Write the knob under *Açık sorular* so the orchestrator adds it to `docs/KNOBS.md` (not in `files:`).
- **Short-window `DataRateLimits` (F A-3):** also try a second pair, e.g. `[bytes, 0.1]` next to the 1 s pair. Report whether `VTSessionSetProperty` accepts it (status code) and whether single-frame sizes change. Diagnostics only; the default stays as today unless the orchestrator decides otherwise.
- Log `video ev=bitrate_set kbps=<n> avg_status=<OSStatus>|skipped limits_status=<OSStatus>`, numbers only, one line per actual change (deduplicated). Add the line to `docs/LOGGING.md`.
- `STREAM_CONFIG.bitrate_kbps` keeps meaning "the configured value". This card sends no new `STREAM_CONFIG`. Any "ceiling" semantics belong to decision 0023 / T-196 (orchestrator prose in §0x03 then).

**Ordering and serialization:**
- Hot-file chain on `HEVCEncoder.swift`: T-162 → T-170 → T-176 → T-177 → T-204 → T-187. The `depends_on` already covers T-162 and T-176; T-170 comes earlier in the same chain.
- `VideoPipeline.swift` is also edited by T-176.
- `EncoderKnobs.swift` is also edited by T-204 (later; it depends on this card) and possibly T-178.

Wire: none.

## Kapsam dışı

- Any controller that decides *when* to change the bitrate (T-195, T-196).
- The `STREAM_PREFS` restart path and PROTOCOL §0x03/§0x05 semantics.
- Making a short-window `DataRateLimits` the default.

## Kabul kriterleri

- [x] [XCTest] Rate-request value type: values clamp to `[floor, ceiling]`, equal consecutive values are deduplicated, and a request after `stop` is rejected.
- [x] [XCTest] Through the T-162 owner-queue seam with a fake backend: set-bitrate calls are ordered with submits, and none reaches the backend after invalidate. Deterministic, with no sleeps.
- [x] [XCTest] Step-knob parser: absent or invalid means off, and the valid form is parsed. Defaults are unchanged.
- [x] [doc] `docs/LOGGING.md` lists `video ev=bitrate_set` with its fields.
- [ ] [device] With the step knob 60→15→60 Mbps on a scrolling page, either `sent_kbps=` in host `net ev=stats` (one line per 1 s client STATS interval, `StreamCoordinator.swift:448-451`) follows each step within ≤1 s, **or** the run records that VT ignores the change. In that case also try `MATEBRIDGE_ENCODER=llrc` at 60 fps and record both. A negative result is a valid outcome: it blocks T-196's encoder half and is written in NOTES. In every case, no video reconnect, no `STREAM_CONFIG`, no new `config_id` and no `restartPipeline` appear in the log. The `VTSessionSetProperty` status codes are recorded in Handoff and docs/NOTES.md (orchestrator).
- [ ] [device] Same check with `MATEBRIDGE_QUALITY` set: record whether frame sizes react (only `DataRateLimits` is set in that mode).
- [ ] [device] Short-window `DataRateLimits` pair: accepted or refused (status), plus the largest frame size (`idr_bytes_max`/frame p99) with and without it, recorded in NOTES.
- [x] `./scripts/check.sh` geçiyor.

## Plan

1. **Core, `EncoderSubmitOrder.swift`:**
   - Saf `BitrateRequest` değer tipi: `[floor, ceiling]` (varsayılan `userBitrateRangeKbps` 5 000…150 000) aralığına kırpar, son uygulanan değere eşit isteği eler (başlangıç değeri yapılandırılmış bit hızı), `stop()` sonrası her isteği reddeder. Kararlar: `.apply(kbps)` / `.unchanged` / `.stopped`.
   - Saf `RateLimitWindows`: `DataRateLimits` çiftleri. Varsayılan bugünkü `[2 × ort. bayt/s, 1 s]`; isteğe bağlı kısa pencere `[2 × ort. bayt/s × w, w]` eklenir.
   - `CompressionBackend`'e `setBitrate(kbps:)` gereksinimi; varsayılan uygulaması boş.
   - `EncoderSubmitOrder.setBitrate(kbps:)`: kilit altında `BitrateRequest`'e sorar. `.apply` ise bloğu kilit tutulurken sahip kuyruğuna ekler. Böylece submit'lerle FIFO sırasında kalır, `stop`'un teardown bloğundan sonra hiçbir set çağrısı backend'e ulaşmaz.
2. **Core, `EncoderKnobs.swift`:**
   - `BitrateStepKnob` (`MATEBRIDGE_BITRATE_STEP=60000,15000,60000@5s`): yoksa ya da geçersizse kapalı; değerler döngüyle uygulanır.
   - `MATEBRIDGE_RATE_WINDOW_MS` (kısa `DataRateLimits` penceresi, tanı amaçlı): 10…999, aksi halde kapalı.
   - İkisi de `EncoderKnobs`'a eklenir, varsayılan kapalı. Doc yorumu kapanış kartını (T-196 ya da T-127 sonrası kaldırma) adlandırır. `logFields` yalnız ayar açıkken alan ekler, böylece varsayılan satır değişmez.
3. **Host, `HEVCEncoder.swift`:**
   - `setTargetBitrate(kbps:)` → `order.setBitrate`.
   - `Backend.setBitrate` sahip kuyruğunda: `qualityApplied` değilse `AverageBitRate`, her durumda `DataRateLimits`. Ardından `video ev=bitrate_set kbps= avg_status=<st>|skipped limits_status=<st>`.
   - Oluşturmada `DataRateLimits` aynı `RateLimitWindows`'tan gelir (varsayılan baytları değişmez).
   - Adım ayarı açıksa bir `DispatchSourceTimer` `setTargetBitrate` çağırır; `beginStop`'ta iptal edilir.
4. **Host, `VideoPipeline.swift`:** `setTargetBitrate(kbps:)` iletici (T-178/T-196 için yapı taşı). STREAM_CONFIG ya da restart yolu yok.
5. **Testler (`Tests/.../Video/`):**
   - `BitrateRequest`: kırpma, eleme, stop sonrası reddetme.
   - Sahte backend ile sıra: set çağrıları submit'lerle sıralı, invalidate sonrası hiçbiri yok (bariyerle, sleep yok).
   - Adım ayarı ve pencere ayrıştırıcısı; varsayılanlar değişmez.
6. **`docs/LOGGING.md`:** ayrı bir "Canlı bit hızı" bölümü.

**Riskler:**
- `.fast` profil (RealTime=false, LLRC yok) `AverageBitRate` değişimini `noErr` ile kabul edip yok sayabilir (T-087 emsali). Bu cihazda ölçülür.
- `CompressionBackend`'e gereksinim eklemek diğer uygulayıcıları etkiler. Varsayılan uygulama bunu önler.

## Handoff

- **Commit:** `6594e1a` (uygulama), plan `a6af709`. Dal `task/T-177-host-live-bitrate-setter`. Bu Handoff ayrı bir commit'te.
- **Dokunulan dosyalar:**
  - `host-mac/Sources/MateBridgeCore/Video/EncoderSubmitOrder.swift`:
    - `BitrateRequest` (kırpma 5 000…150 000 = `VideoSettings.userBitrateRangeKbps`, eleme, stop sonrası `.stopped`).
    - `RateLimitWindows`.
    - `CompressionBackend.setBitrate(kbps:)` (varsayılan boş).
    - `EncoderSubmitOrder.setBitrate(kbps:)` / `currentBitrateKbps`, init'te `initialBitrateKbps:` ve `bitrateRange:` (varsayılanlı, mevcut çağıranlar değişmedi).
  - `host-mac/Sources/MateBridgeCore/Video/EncoderKnobs.swift`: `BitrateStepKnob`, `EncoderKnobs.bitrateStep` / `rateWindowMs`, `logFields` (yalnız ayar açıkken alan ekler).
  - `host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift`:
    - `setTargetBitrate(kbps:)`, `applyBitrate` (sahip kuyruğu), `Backend.setBitrate`.
    - Adım zamanlayıcısı (`beginStop`'ta iptal edilir).
    - `dataRateLimits(kbps:shortWindowMs:)`: oluşturmada da kullanılır. Varsayılan değer `[Int, 1]` olarak kalır, T-177 öncesiyle aynı.
  - `host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift`: `setTargetBitrate(kbps:)` iletici. Henüz hiçbir çağıran yok (T-178/T-196 bağlayacak).
  - `host-mac/Tests/MateBridgeCoreTests/Video/LiveBitrateTests.swift` (yeni, 12 test).
  - `host-mac/Tests/MateBridgeCoreTests/Video/EncoderSubmitOrderTests.swift`: sahte backend `setBitrate`'i kaydediyor, 3 yeni sıra testi (bariyerle, sleep yok).
  - `docs/LOGGING.md`: yeni "Canlı bit hızı (Mac, `video`, T-177)" bölümü, dosyanın sonunda ayrı blok.
- **Varsayımlar:**
  - Kısa pencere çifti `[2 × ort. bayt/s × w, w]`, yani 1 s çiftiyle aynı 2× pay. 60 Mbps'te 100 ms → 1,5 MB.
    - Bu değer tek bir 100–450 KB kareyi sınırlamaz. Tek kareyi etkilemesi için `w` yaklaşık bir kare süresi olmalı (60 fps'te 16–33 ms). Cihazda `MATEBRIDGE_RATE_WINDOW_MS=33` ve `=100` ayrı denenmeli.
    - Aralık 10…999 ms. Kart bayt değerini açık bırakmıştı.
  - `MATEBRIDGE_BITRATE_STEP` değerleri döngüyle uygulanır. İlk değer encoder kurulduktan bir periyot sonra verilir.
    - Her encoder yeniden kurulumunda (mod değişimi, bekletmeden dönüş) baştan başlar.
    - Yapılandırılmış değere eşit adım satır üretmez (eleme).
  - Değişiklik keyframe zorlamaz.
  - `bitrate_set` satırı `encoder` yerine `video` bileşeniyle yazılır (kartın istediği gibi). Doğrudan `HostLog`'a gider; bench'lerin `logSink`'ine gitmez.
  - Hız kontrolü, istemcinin `sent_kbps`'i ve `STREAM_CONFIG` değişmedi. Wire değişikliği yok.
- **Test edilmeyenler / cihazda doğrulanacaklar** (uygulama çalıştırılmadı, GUI açılmadı):
  1. `MATEBRIDGE_BITRATE_STEP=60000,15000,60000@5s` ile kayan bir sayfada şunlar not edilir:
     - `video ev=bitrate_set` satırlarındaki `avg_status` / `limits_status` kodları.
     - `net ev=stats` `sent_kbps=` her adımı ≤1 s içinde izliyor mu? Varsayılan `.fast` profil (`RealTime=false`, LLRC yok) T-087'deki gibi kabul edip yok sayabilir.
     - Log'da `STREAM_CONFIG`, yeni `config_id`, video yeniden bağlanması ya da `restartPipeline` / `stream_reconfigure` olmamalı.
  2. Olumsuzsa aynı ölçüm `MATEBRIDGE_ENCODER=llrc` ile 60 fps'te tekrarlanır; iki sonuç da NOTES'a yazılır.
  3. `MATEBRIDGE_QUALITY=0.6` gibi bir değerle `avg_status=skipped` görülmeli; kare boyutlarının yalnız `DataRateLimits`'e tepki verip vermediği kaydedilir.
  4. `MATEBRIDGE_RATE_WINDOW_MS=33` ve `=100` için:
     - `encoder_set[…DataRateLimits=…]` oluşturmada kabul/ret kodu, ve `bitrate_set limits_status`.
     - Ayarlı ve ayarsız `idr_bytes_max` ve kare p99 karşılaştırması.
  5. Durdurma, yeniden kurma ve bekletmeden dönüşte adım zamanlayıcısının iptal edildiği (eski encoder'dan `bitrate_set` gelmemeli). Kodla güvenceli (`beginStop` + sahip kuyruğu), ama log'da da görülmeli.
- **Açık sorular:**
  - **KNOBS.md satırları** (dosya kapsamım dışında; orkestratör ekler, "Planlanan ayarlar"daki T-177 maddesinin yerine):
    - `| 41 | \`MATEBRIDGE_BITRATE_STEP=<kbps>[,<kbps>…]@<n>s\|<n>ms\` | yok (kapalı) | EK:144-191, :225; HE:256-263, :550-579, :700; \`EncoderSubmitOrder.swift:52-86\`, :236-251 | T-177 | yalnızca geliştirici | Canlı bit hızı cihaz denetimi; zamanlayıcıyla canlı ayarlayıcıyı adımlar (döngüsel) | T-196 (benimser) ya da T-127 sonrası kaldırılır |`
    - `| 42 | \`MATEBRIDGE_RATE_WINDOW_MS\` | yok (yalnız 1 s çifti) | EK:207-209, :226; HE:220-223, :276-285; \`EncoderSubmitOrder.swift:88-105\` | T-177 (F A-3) | yalnızca geliştirici | Kısa \`DataRateLimits\` penceresi tanısı; varsayılan değişmez | T-196 ya da T-127 sonrası kaldırılır |`
    - Not: satır numaraları 40'tan devam ediyor. Host CLI tablosunda da bir "40" var; orkestratör numaralamayı kendi düzenine göre ayarlamalı.
  - Bu kart `STREAM_CONFIG.bitrate_kbps` anlamını değiştirmiyor. Canlı değişiklik sonrası istemcinin gördüğü değer "yapılandırılmış" olarak kalır. Tavan semantiği 0023 / T-196'ya ait.
  - Sorun ya da kapsam dışı ihtiyaç yok.
