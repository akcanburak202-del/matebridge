---
id: T-175
title: Time host input delivery, environment lookups and CGEventPost per message
status: review
phase: 6
owner: mac-host-dev
depends_on: [T-171]
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Input/InputController.swift
  - host-mac/Sources/MateBridgeHost/Input/CGEventPoster.swift
  - host-mac/Sources/MateBridgeHost/Input/VirtualDisplayLocator.swift
  - host-mac/Sources/MateBridgeCore/Input/
  - host-mac/Tests/MateBridgeCoreTests/Input/
  - docs/LOGGING.md
  - backlog/tasks/T-175-host-input-delivery-timing.md
---

## Amaç

Every input message is delivered synchronously from the session queue onto the input queue, and on each message the host queries display geometry through CoreGraphics and builds a new `CGEventSource` per event. None of these costs is measured. If one call stalls, the session queue cannot read control bytes, drain audio, answer PINGs or run the heartbeat tick, and a block of more than 1.5 s can cause a false silence release. This card measures per-message delivery, environment and post time and reports them per session, so any optimisation is decided with data. It is an R-tagged finding (L03): measurement first, optimisation only as a follow-up.

Source: external architecture review 2026-10-03 (L03 input side, W4 "Mac input"); verification: docs/reviews/2026-10-03/verify-F-network.md (F-6, W4 Mac input), docs/reviews/2026-10-03/verify-G-input.md (P-L03i, L03, additional issue 7), docs/reviews/2026-10-03/coverage-audit.md (§4.3 merge, §4.4 severity).

## Bağlam

**Evidence:**
- `InputController.deliver` (`InputController.swift:177-200`) runs `queue.sync` from the session queue; the header (`:8-14`) states that blocking the session queue is the intended back-pressure (`SessionServer` → `handlers.deliver` → `input.deliver`, `MateBridgeApp/main.swift:156-161`).
- Per message on the input queue:
  - `environment()` (`:320-338`) → `isTrusted()` (AX, cached 200 ms, `:341-347`) and `displays.geometry()`.
  - `VirtualDisplayLocator.geometry()` (`VirtualDisplayLocator.swift:33-44`) runs `isOurs(id)` = `CGDisplayIsOnline`/`CGDisplayVendorNumber`/`CGDisplayModelNumber` (`:67-68`) and `geometry(of:)` = `CGDisplayBounds` + `CGDisplayCopyDisplayMode` (`:80-88`) on **every** message; only the display ID is cached. While drawing that is ~360 calls/s.
  - `capsLock.isOn()` for KEY; `liveCursor()` for POINTER_REL only (already timed, `:251-260`; ~5 µs avg on device, NOTES ~l.723).
  - `flush` → `CGEventPoster.post` (`:283-308`), which builds `CGEventSource(stateID: .hidSystemState)` per event (`CGEventPoster.swift:46-49`). Untimed.
- What blocks while `deliver` blocks (verify-F W4): control reads (`SessionServer` connection on the session queue), the 100 ms tick (silence release at 1.5 s, close at 5 s, `SessionMachine.swift:514-521`), `drainAudio` (audio downlink) and PONG replies (client reconnects after 3 s without PONG). The input watchdog (500 ms) runs on the same input queue (`InputController.swift:79-86`).
- Counter-evidence (verify-G): USB contact → Mac event median 2 ms, max 5 ms (NOTES 2026-09-30), so a large per-message cost is unlikely. Hence measure, do not refactor.

**R-tag rule (review p11, manifest):** the card starts with a deterministic scenario committed red before the timing code: a pure aggregate fed with a synthetic session that includes one slow call must yield the expected fields and exactly one warning.

**Plan hints:**
- Pure aggregate helper in `MateBridgeCore/Input/` (e.g. `InputTiming.swift`, new): fixed-size histogram for deliver µs, sums/max for env and post µs, slow-call warning rate limiter (e.g. at most one line per 10 s). Testable in XCTest; the Host-side wiring is not (only `MateBridgeCoreTests` exists).
- Timing pattern: `DispatchTime.now().uptimeNanoseconds` around the calls, as `liveCursor()` does (`InputController.swift:251-260`).
- Definitions: `deliver_us` = the caller-side duration of `input.deliver` (around `queue.sync`, including the wait for the input queue while the watchdog or a poll runs), because session-queue blocking is what this card is about; timing inside `queue.sync` would miss that wait. `env_us`/`post_us` are measured inside, on the input queue.
- `CGEventPoster.swift` and `VirtualDisplayLocator.swift` may be touched **only** to add timing hooks, not to change behaviour.
- Also exercise the worst case: a display reconfiguration (mode switch) during input.
- Follow-up only if the numbers justify it (> ~50 µs per message, or p99 deliver above a few ms): cache geometry until `CGDisplayRegisterReconfigurationCallback`; reuse one `CGEventSource` (changes event provenance, needs a Krita pen check); move `drainAudio` off the session queue. Each would be its own card.

**Order and hot files:** `InputController.swift` chain T-163 → T-171 → **T-175** → T-198 / T-199. T-171 is a dependency. Codex review: not required (diagnostics only, no input-state change), but the orchestrator may request it since the file is on the input path.

## Kapsam dışı

- Any optimisation (geometry cache, event-source reuse, threading changes). Follow-up cards only, with data.
- Changing the session/input queue model or the watchdog.
- Input age (T-171).

## Kabul kriterleri

- [x] [XCTest] Deterministic scenario, committed red before the helper is implemented: a synthetic session of N messages with ~30 µs environment and ~20 µs post each, plus one 25 ms post, yields the expected `deliver_us_avg/p99/max`, `env_us_avg/max`, `post_us_avg/max` and exactly one slow-call warning (threshold 20 ms); a second slow call inside the rate-limit window yields no second warning.
- [x] [XCTest] The aggregate is fixed-size (no growth with message count) and resets per session.
- [x] `input_session_end` gains `deliver_us_avg= deliver_us_p99= deliver_us_max= env_us_avg= env_us_max= post_us_avg= post_us_max=`, and a rate-limited `W input ev=input_slow_call stage=env|post|deliver us=` line appears when one call exceeds 20 ms. No coordinates, keys or characters in either.
- [x] Timing adds no behaviour change: same events posted in the same order (existing input tests stay green).
- [x] [doc] `docs/LOGGING.md` documents the new fields and the warning line.
- [ ] [device] 10 min of mixed pen, keyboard and trackpad use plus one mode switch during input: the `input_session_end` numbers are recorded in NOTES with build IDs, with a one-line verdict "optimise / not needed" against the > 50 µs/message or p99 > few-ms threshold.
- [x] `./scripts/check.sh` geçiyor.

## Plan

1. **Saf toplayıcı** `MateBridgeCore/Input/InputDeliveryTiming.swift` (yeni): mesaj başına `deliverNs/envNs/postNs` alır. `deliver` için T-171'in sabit boyutlu `AgeHistogram`'ı (µs, p99), env ve post için toplam + max (ns). Eşik 20 ms (kesin büyük). Bir mesajda en çok bir uyarı: `post` ya da `env` eşiği aştıysa büyük olanı, yoksa `deliver` (bekleme ya da diğer iş). Hız sınırı: 10 s'de en çok bir satır. Bastırılanlar `slow_calls=` ile oturum sonunda sayılır. `reset()` oturum toplamlarını sıfırlar, hız sınırının zamanını korur (yeniden bağlanma fırtınası uyarı yağdırmasın).
2. **Kırmızı senaryo önce**: `Tests/MateBridgeCoreTests/Input/InputDeliveryTimingTests.swift` + boş gövdeli API iskeleti (derlenir, testler kırmızı). Ayrı commit.
3. **Uygulama**, sonra testler yeşil.
4. **Bağlama** (`InputController.swift`): `deliver`'da `queue.sync` dışında (çağıran tarafı, oturum kuyruğu) `deliver_us`. İçeride `env_us` = `environment()` + KEY için `capsLock.isOn()` (canlı imleç hariç; kendi alanları var). `post_us` = `flush` içindeki `post(events)` (izin kontrolü + `poster.post`). Toplayıcı ayrı bir `NSLock` altında (kayıt `queue.sync` sonrası oturum kuyruğunda olur). Uyarı satırı oturum/yapılandırma kimliğini blok içinden alır. `sessionStarted` sıfırlar, `sessionEnded` alanları `input_session_end`'e ekler. PONG ve girdi dışı mesajlar ölçülmez.
5. `CGEventPoster.swift` / `VirtualDisplayLocator.swift`'e dokunulmaz: denetleyici düzeyinde ölçüm kabul kriterlerini karşılar, davranış riski sıfır.
6. `docs/LOGGING.md`: ayrı "Girdi teslim zamanlaması (T-175)" bölümü.

**Riskler:** zaman ölçümü (`DispatchTime.now()` ~25 ns) dışında davranış değişmez. Olay sırası ve içeriği aynı. Kilit sırası: `timingLock` hiçbir zaman `queue` beklenirken tutulmaz, kilitlenme olmaz.

## Handoff

- **Commit:** `082ea7b` plan, `fdb5a01` kırmızı senaryo (iskelet API, 6 testin hepsi kırmızı), `cb36f4b` uygulama + bağlama + LOGGING, ardından bu handoff commit'i. Dal: `task/T-175-host-input-delivery-timing`.
- **Dokunulan dosyalar:**
  - `host-mac/Sources/MateBridgeCore/Input/InputDeliveryTiming.swift` (yeni): saf toplayıcı. `deliver` için T-171'in `AgeHistogram`'ı (µs), env/post için doygun toplam + max (ns), 20 ms eşik, 10 s hız sınırı, `slow_calls` sayacı.
  - `host-mac/Tests/MateBridgeCoreTests/Input/InputDeliveryTimingTests.swift` (yeni): 6 test (R-tag senaryosu, boş oturum, aşama seçimi + eşik sınırı, sabit boyut + oturum sıfırlama, hız sınırı sıfırlamadan sağ çıkar, uç değerler).
  - `host-mac/Sources/MateBridgeHost/Input/InputController.swift`: `deliver` ölçümü (`queue.sync` çevresi + içeride env/caps ve post), `flush` artık post süresini döndürür (`@discardableResult`, diğer çağıranlar değişmedi), `timingLock` + `timing`, `sessionStarted` sıfırlar, `sessionEnded` alanları ekler, `W input ev=input_slow_call`.
  - `docs/LOGGING.md`: ayrı "Girdi teslim zamanlaması (Mac, `input`, T-175)" bölümü (T-171 bölümünden hemen sonra).
  - `CGEventPoster.swift` ve `VirtualDisplayLocator.swift`'e **dokunulmadı** (denetleyici düzeyindeki ölçüm yeterli).
- **Varsayımlar:**
  - `env_us` = `environment()` + KEY için `capsLock.isOn()`. Canlı imleç (`liveCursor`) hariç, kendi `cursor_query_*` alanları var. Kapı değişiminde yazılan `input_gate`/`input_displays` log satırlarının maliyeti de `env`'e girer (mod değişiminde bu gerçek maliyettir).
  - `post_us` = `flush` içindeki `post(events)`: kapanış olayı varsa taze izin kontrolü + `poster.post`. `postFailed`, `logRecords` ve log satırları hariç. Olay üretmeyen mesajda ~0.
  - Ölçülen mesajlar: `deliver`'ın girdi dalındaki her şey (PEN, POINTER_REL/ABS, SCROLL, PINCH, PEN_GESTURE, KEY, RELEASE_ALL, BYE). PONG ve diğerleri ölçülmez. `stopped` sonrası mesaj kaydedilmez.
  - Kartın listelediği alanlara ek olarak `slow_calls=<n>` eklendi (hız sınırıyla bastırılanlar dahil sayım). Gerekmiyorsa kaldırmak tek satır.
  - Hız sınırı zamanı `reset()`'te korunur: yeniden bağlanma fırtınasında oturum başına bir uyarı yağmaz. Oturum toplamları ise her oturumda sıfırdan.
  - Eşik "kesin büyük" (tam 20 000 µs yavaş sayılmaz). Bir mesajda env ve post ikisi de aşarsa büyüğü adlandırılır, yine tek satır.
  - Davranış: olaylar aynı sırada ve aynı içerikle, aynı anda gönderilir. Tek fark `DispatchTime.now()` çağrıları ve `queue.sync` sonrası kısa bir kilit + nadir log satırı (oturum kuyruğunda, girdi kuyruğunun dışında). `InputController` Host hedefinde olduğu için birim testi yok. "Davranış değişmedi" kanıtı kod incelemesi + yeşil kalan 763 test.
- **Test edilmeyenler / cihazda doğrulanacaklar:**
  - [device] 10 dk karışık kalem + klavye + trackpad, girdi sırasında bir mod değişimi (çözünürlük/ölçek). `input_session_end` satırındaki `deliver_us_* env_us_* post_us_* slow_calls` değerleri build kimliğiyle NOTES'a, tek satır karar: > ~50 µs/mesaj ya da `deliver_us_p99` birkaç ms üstü → optimizasyon kartı, değilse "gerek yok".
  - Mod değişiminde `ev=input_slow_call stage=env` görülüp görülmediği (en olası yavaş an: `CGDisplayCopyDisplayMode` / yeniden tarama).
  - Gerçek CGEvent gönderilmedi, uygulama başlatılmadı, GUI açılmadı.
- **Açık sorular:**
  - Post süresinin `CGEventSource` kurma ile `post` arasında bölünmesi istenirse `CGEventPoster`'a ince bir zaman kancası gerekir. Kart buna izin veriyor ama kabul kriterleri gerektirmiyor. Cihaz sayıları `post_us` yüksek çıkarsa izleyen kartta yapılabilir.
