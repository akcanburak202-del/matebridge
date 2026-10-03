---
id: T-205
title: Promote an AUTO USB migration candidate only after its first authenticated host record
status: in_progress
phase: 6
owner: android-client-dev
depends_on: [T-150]
decisions: [0018]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionMachine.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionController.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/session/MigrationTest.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/session/MigrationAuthGateTest.kt
  - backlog/tasks/T-205-client-migration-auth-gate.md
---

## Amaç

In AUTO mode the tablet moves a live Wi-Fi session to USB (T-096) as soon as the USB candidate's **plaintext** HELLO_ACK says PAIRED/ACCEPTED, before the host has proved it holds the pair key. A tablet app squatting `127.0.0.1:47001` that knows the real `host_id` (clear in every ack) can therefore pull a working session onto itself and kill it (DoS; everything after the ack is sealed, so nothing leaks). After this card a candidate is promoted only when its first host record authenticates. Until then the Wi-Fi session stays current and keeps carrying input, so no up event is lost. A squatter candidate fails and AUTO backs off. This was the migration part of T-150, split out by QA-1 (T-150 #6) so that each card fits one context window.

Source: external architecture review 2026-10-03 (A2(iii)); verification: docs/reviews/2026-10-03/verify-A2-adversarial.md (migration side finding); coverage audit §4.7; QA-1 (T-150 #6).
Decision 0018 must be accepted by the user before work starts ("Taşıma adayı, ancak ilk doğrulanmış host kaydından sonra terfi eder").

## Bağlam

`C/` = `client-android/app/src/main/kotlin/dev/matebridge/client/`. Lines are at HEAD a30c769; T-150 lands first and moves some of them, so re-check them.

- **Evidence:**
  - A T-096 candidate is promoted on the plaintext PAIRED/ACCEPTED first ack (`C/session/SessionMachine.kt:463` → `promote` :492-511; posted at `C/session/SessionController.kt:677`), before any authenticated host record.
  - `AutoUsbPolicy` migrates every interval while the session is ACCEPTED and the cable is not reported DISCONNECTED (`C/session/AutoTransport.kt:193-201`). The probe and the candidate both target `127.0.0.1:47001`, which any app with INTERNET can bind whenever `adb reverse` does not hold it.
  - The candidate already never pairs: `candidateKeys.put` throws (`SessionController.kt:154-161`) and a PENDING ack aborts (`SessionMachine.kt:465`). T-150 keeps that and adds the trust flags.
  - Host side: on the candidate's first authenticated record the host supersedes the old session (BYE(SUPERSEDED) + close on the old connection), then answers the proof with STREAM_CONFIG and PONG (host `SessionMachine.swift:696-716`). After T-152 every PAIRED connection works this way.
- **Design (recommended shape; the implementer may refine names, not semantics):**
  - On the candidate's plaintext ACCEPTED, send the proof PING **on the candidate** while the Wi-Fi session stays current. Promote only when the candidate's first host record authenticates.
  - The real host supersedes the old session on that proof, and the BYE(SUPERSEDED) and close on the old connection may arrive **before** the candidate's first record. While a proved candidate is pending they must not trigger `lose()`.
  - **Keep input flowing on the current (Wi-Fi) generation until the promotion itself**; then the existing gate switch applies (`SessionController.kt:372`). Do **not** close the input gate during the proof wait: if the candidate is a squatter, the real host never supersedes, and an up event refused meanwhile would stay stuck on the Mac (AGENTS.md hard rule). When the real host does supersede, it releases everything held on the old connection before dropping it (PROTOCOL §3, §7), so inputs it discards are harmless.
  - A bad first record, a close, or the 3 s candidate deadline (`MIGRATE_TIMEOUT_US`) aborts the candidate with a reason that `AutoUsbPolicy.outcomeOf` maps to HARD_FAIL (`AutoTransport.kt:251-255`; `SOFT_REASONS` :275-278), so AUTO backs off instead of retrying every interval. Reasons outside `SOFT_REASONS` are already HARD_FAIL, so no `AutoTransport.kt` change is expected. If one is needed, stop and write it under *Açık sorular*.
  - The candidate inherits the locally trusted state of the session it replaces (same `host_id`, same trusted key). It never stores or pends a key (T-150 rule).
  - `MigrationTest.successfulMigrationRetiresThenPromotesThenProvesFirst` (`client-android/app/src/test/kotlin/dev/matebridge/client/session/MigrationTest.kt:57-98`) encodes today's order (retire, promote, prove) and is rewritten for the new order (prove, then retire and promote).
  - Alternative allowed: "tentative promotion with rollback to the retired connection", if every acceptance criterion holds. Say which one in Handoff.
- **Logging:** e.g. `migration_proof_wait` and the existing migration result line with the new reason. No `host_id`, key or token in fields. `docs/LOGGING.md` additions go under *Açık sorular*.
- **Serialize with:** T-150 (depends_on), T-156, T-160, T-183 and T-197 (same files `SessionMachine.kt` / `SessionController.kt`; chain T-150 → T-205 → T-156 → T-160 → T-197). None of them depends on this card, so run them one at a time and never in parallel with this one. T-151, T-156, T-160, T-185, T-190 and T-197 list the whole `test/.../session/` directory: do not touch `MigrationTest.kt` in parallel with them.
- No wire change; `docs/PROTOCOL.md` is not affected. Its §3 takeover prose already describes the host side (proof by the first authenticated record, then BYE(SUPERSEDED) to the old connection); the client's promotion order is not visible on the wire.
- **Review:** input-state and security change: the orchestrator runs `./scripts/codex-review.sh main task/T-205-… --high`.

## Kapsam dışı

- Trust store, local confirmation and pairing UI (T-150, T-151); host changes (T-152); `KEY_MISMATCH` (T-156).
- AUTO policy tuning (intervals, backoff values), USB fallback rules.

## Kabul kriterleri

- [ ] [JVM] An AUTO-mode USB migration candidate that receives a plaintext PAIRED/ACCEPTED ack is **not** promoted until its first host record decrypts and authenticates.
- [ ] [JVM] **Squatter candidate.** A candidate that knows the real `host_id` and then sends a bad record, closes, or sends nothing within the candidate deadline is aborted. The live Wi-Fi session is untouched: no `lose`, no reconnect, `inputAllowed` stays true on the Wi-Fi generation, video is not closed. The abort reason maps to HARD_FAIL in `AutoUsbPolicy.outcomeOf`.
- [ ] [JVM] **No lost up event.** A key (and, separately, a pen contact) pressed on the Wi-Fi generation before the candidate opens and released during the proof wait: the up is sent on the Wi-Fi connection, for both a squatter candidate and a real one. A squatter candidate never causes any input on the live session to be refused or dropped.
- [ ] [JVM] **Normal migration still promotes.** The old video closes once, exactly one new video connection opens after STREAM_CONFIG, and there is no extra `KEYFRAME_REQUEST` beyond today's. A BYE(SUPERSEDED) or a close on the old connection that arrives before the candidate's first record does not end the session. No input from the old generation reaches the new session.
- [ ] [JVM] A PAIRING ack on a candidate still aborts the migration and touches neither the trusted nor the pending record.
- [ ] [JVM] `MigrationTest` is rewritten for the new order; the other migration, wake and AUTO tests pass, rewritten only where they encode the old order (list them in Handoff).
- [ ] [device] Covered by T-157 step 7.
- [ ] The orchestrator ran `./scripts/codex-review.sh` with `--high` and its findings are resolved or recorded.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

Seçilen şekil: önerilen sıra (önce kanıt, sonra emekliye ayırma + terfi); "geri almalı geçici terfi" değil.

1. `SessionMachine.kt`: adayın şifresiz ACCEPTED'ı artık terfi etmez. Aday *kanıt bekliyor* durumuna geçer, ack'i (host adı, session_id, video portu) saklanır, kanıt PING'i **adayın** üstünden gider (`SendCandidate(Ping)`), `migration_proof_wait` loglanır. Wi-Fi oturumu current kalır: `inputAllowed`/`acceptedGen` değişmez, video kapanmaz, ping'ler sürer.
2. Adaydan gelen ilk kayıt (okuyucu yalnız çözülüp doğrulanan kaydı `Received` olarak verir) terfiyi tetikler: eski video kapanır, eski kontrol emekliye ayrılır, aday terfi eder, ayarlar (STREAM_PREFS, DISPLAY_RATE, AUDIO_PREFS, FILES_INFO) aynı FIFO'da kanıt PING'inin arkasından gider, `MigrationResult(ok)`, sonra o ilk kayıt yeni oturumun mesajı olarak işlenir (STREAM_CONFIG → video açılır, emekli kapanır). İkinci PING yok.
3. Kanıt beklenirken eski bağlantıda BYE(SUPERSEDED) ya da kapanma `lose()` çağırmaz: "eski gitti" işaretlenir; o arada eski bağlantıda PONG zaman aşımı, ping ve video yeniden açma durur, karar aday süresine kalır. Aday sonra başarısız olursa (süre, kapanma, iptal) oturum normal `lose()` ile yeniden bağlanır (takılı kalmaz).
4. Kanıt sırasında hatalar yeni sebeplerle biter: `proof_failed` (bozuk kayıt / ProtocolError), `proof_closed` (kapanma ya da BYE), `proof_timeout` (3 s `MIGRATE_TIMEOUT_US`). Hiçbiri `SOFT_REASONS` içinde değil → HARD_FAIL; `AutoTransport.kt` değişmez.
5. Adayın `Secured` olayı: anahtar asla saklanmaz (sıfırlanır); host_id oturumunkinden farklıysa aday `key` sebebiyle düşer (aynı Mac, aynı güvenilen anahtar).
6. `SessionController.kt`: davranış değişmez (kapı terfi anında kapanıp açılır, `SendCandidate` PING'i de mühürler); yorumlar/loglar yeni sıraya göre güncellenir.
7. Testler: `MigrationTest` yeni sıraya göre yeniden yazılır; yeni `MigrationAuthGateTest` gerçek kriptolu sahte host + denetleyicinin yönlendirme modeliyle: squatter (bozuk kayıt, kapanma, süre), kayıp up olmaması (tuş ve kalem), normal taşıma, PAIRING ack, host_id uyuşmazlığı, eski gittikten sonra aday düşerse yeniden bağlanma.

Riskler: `MigrationCancelTest.cancelWithoutCandidateOrAfterPromotionDoesNothing` eski sırayı kodluyor (ack'te terfi) ve `files:` listesinde yok; kabul kriteri "eski sırayı kodlayan testler yeniden yazılır, Handoff'ta listelenir" dediği için en küçük değişiklikle uyarlanacak ve Handoff'ta belirtilecek.

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
