---
id: T-205
title: Promote an AUTO USB migration candidate only after its first authenticated host record
status: review
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

- [x] [JVM] An AUTO-mode USB migration candidate that receives a plaintext PAIRED/ACCEPTED ack is **not** promoted until its first host record decrypts and authenticates.
- [x] [JVM] **Squatter candidate.** A candidate that knows the real `host_id` and then sends a bad record, closes, or sends nothing within the candidate deadline is aborted. The live Wi-Fi session is untouched: no `lose`, no reconnect, `inputAllowed` stays true on the Wi-Fi generation, video is not closed. The abort reason maps to HARD_FAIL in `AutoUsbPolicy.outcomeOf`.
- [x] [JVM] **No lost up event.** A key (and, separately, a pen contact) pressed on the Wi-Fi generation before the candidate opens and released during the proof wait: the up is sent on the Wi-Fi connection, for both a squatter candidate and a real one. A squatter candidate never causes any input on the live session to be refused or dropped.
- [x] [JVM] **Normal migration still promotes.** The old video closes once, exactly one new video connection opens after STREAM_CONFIG, and there is no extra `KEYFRAME_REQUEST` beyond today's. A BYE(SUPERSEDED) or a close on the old connection that arrives before the candidate's first record does not end the session. No input from the old generation reaches the new session.
- [x] [JVM] A PAIRING ack on a candidate still aborts the migration and touches neither the trusted nor the pending record.
- [x] [JVM] `MigrationTest` is rewritten for the new order; the other migration, wake and AUTO tests pass, rewritten only where they encode the old order (list them in Handoff).
- [ ] [device] Covered by T-157 step 7.
- [ ] The orchestrator ran `./scripts/codex-review.sh` with `--high` and its findings are resolved or recorded.
- [x] `./scripts/check.sh` geçiyor.

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

- **Commit:** `7759458` (uygulama + testler) on `task/T-205-client-migration-auth-gate`; plan `147633c`; `main` birleştirmesi `b528761` (T-153 dahil); codex P2 düzeltmesi `84faf80`. Şekil: önerilen sıra (önce kanıt, sonra emekliye ayırma + terfi), "geri almalı geçici terfi" değil.
- **Codex (--high) P2, düzeltildi (`84faf80`):** kanıt beklenirken eski Wi-Fi bağlantısının PONG zaman aşımı artık `lose()` değil, eski bağlantının kapanması gibi işlenir (`migration_old_gone how=pong_timeout`): ping/PONG zaman aşımı/video yeniden açma durur, giriş kapısı açık kalır (bırakmalar reddedilmez, Wi-Fi nesline gider), kararı adayın süresi verir; aday düşerse `lose(LOST)` ile yeniden bağlanır. Regresyon testleri: `MigrationAuthGateTest.oldHeartbeatExpiringDuringTheProofDoesNotAbortAValidMigration` (son PONG 2.9 s önce, kanıt, +150 ms tick, sonra terfi) ve `oldHeartbeatExpiredAndASquatterCandidateReconnects`. Düzeltme kapatılınca ikisi de kırılıyor (mutasyonla doğrulandı). Kanıttan önce (ack gelmeden) eski bağlantının PONG zaman aşımı eskisi gibi oturumu kaybeder.
- **T-153 sırası:** terfide `PromoteCandidate` (denetleyicide `onConnectionGen`) her zaman `ApplyConfig`'ten önce gelir; yeni regresyon testi bunu da doğrular (`FilesSessionGate` terfi eden nesli STREAM_CONFIG'ten önce görür). `FilesLifecycleTest` geçiyor.
- **`MigrationCancelTest.kt` düzenlemesi:** orkestratör onayladı.
- **Dokunulan dosyalar:**
  - `client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionMachine.kt`: adayın şifresiz ACCEPTED'ı yalnız `SendCandidate(Ping)` (kanıt) üretir ve `migration_proof_wait` loglar; adayın ilk `Received` kaydı (okuyucu yalnız çözülüp doğrulanmış kaydı verir) terfi ettirir (`CloseVideo`, `RetireControl`, `PromoteCandidate`, ayarlar, `Ui(Connected)`, `MigrationResult(ok)`, sonra o kayıt yeni oturumun mesajı olarak işlenir: STREAM_CONFIG → `CloseRetired` + `ApplyConfig` + `OpenVideo`). Kanıt beklerken eski bağlantıdaki BYE(SUPERSEDED) ya da kapanma `lose()` yapmaz (`oldGone`, log `migration_old_gone how=bye|closed`); o arada eski bağlantıda ping, PONG zaman aşımı ve video yeniden açma durur. Aday sonra düşerse (`failCandidate`) oturum `lose(LOST)` ile yeniden bağlanır. Yeni sebepler: `proof_failed`, `proof_closed`, `proof_timeout` (hepsi `SOFT_REASONS` dışında → HARD_FAIL; `AutoTransport.kt` değişmedi). Adayın `Secured` olayı anahtarı asla saklamaz (sıfırlar); host_id oturumunkinden farklıysa `key` ile düşer. Terfi logu `migration_proved cand_gen=N`.
  - `client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionController.kt`: yalnız yorumlar (davranış aynı: kapı terfi anında kapanıp açılır, `SendCandidate` PING'i adayın yazarı mühürler).
  - `client-android/app/src/test/kotlin/dev/matebridge/client/session/MigrationTest.kt`: yeni sıraya göre yeniden yazıldı (`successfulMigrationProvesThenRetiresAndPromotes`; `retiredConnection…`, `stopAfterPromotion…`, `backToBack…` artık ack + ilk kayıt ile terfi eder).
  - `client-android/app/src/test/kotlin/dev/matebridge/client/session/MigrationAuthGateTest.kt` (yeni, 9 test): gerçek kripto (`PairTrustFlowTest.FakeHost`, `ClientHandshake`, `FirstAck`, `RecordDecoder`) + denetleyicinin yönlendirme aynası (`dispatch`/`exec`/`trySendInput`). Squatter: bozuk kayıt / kapanma / süre; kayıp up yok (tuş ve kalem, squatter ve gerçek); gerçek taşıma (BYE+kapanma önce gelir, video bir kez kapanır, tek OpenVideo, KEYFRAME_REQUEST yok, eski nesil girdi yeni oturuma gitmez); eski gittikten sonra aday düşerse yeniden bağlanma; kanıt sırasında iptal; PAIRING ack kayıtlara dokunmaz; başka host_id'li aday.
  - **`files:` dışında:** `client-android/app/src/test/kotlin/dev/matebridge/client/session/MigrationCancelTest.kt`, `cancelWithoutCandidateOrAfterPromotionDoesNothing` içinde 2 satır (+1 import): terfi artık ack + ilk doğrulanmış kayıt ile. Eski sırayı (ack'te terfi) kodluyordu; kabul kriteri "eski sırayı kodlayan testler yeniden yazılır, Handoff'ta listelenir" dediği için en küçük uyarlama yapıldı. Başka test değişmedi (wake, AUTO, PairTrustFlow olduğu gibi geçiyor).
  - Bu kart.
- **Varsayımlar:**
  - Host kanıtta önce eski oturumu sonlandırır (BYE(SUPERSEDED) + kapatma), sonra adaya STREAM_CONFIG, sonra PONG gönderir (`host SessionMachine.swift` `prove()`), yani adayın ilk kaydı normalde STREAM_CONFIG. İlk kayıt başka bir şeyse (ör. PONG) de terfi olur; emekli bağlantı o zaman `RETIRE_TIMEOUT_US` ile kapanır.
  - Adayın ilk doğrulanmış kaydı BYE ise terfi yok: `proof_closed` (eski gitmişse oturum yeniden bağlanır).
  - Kanıt beklerken eski bağlantının herhangi bir kapanması (yalnız host devralması değil, ör. Wi-Fi kopması) da `oldGone` sayılır; aday 3 s içinde kanıtlamazsa oturum yeniden bağlanır. Bu arada giden girdi ölü kuyruğa düşer; host bağlantı kopunca her şeyi bırakır (PROTOCOL §7), takılı tuş/kalem kalmaz. Eski bağlantıda ProtocolError ya da başka nedenli BYE eskisi gibi `lose()` (adayı da kapatır).
  - Kanıt sırasında giriş kapısı açık kalır (kart gereği); eski gittikten sonra yapılan girdi reddedilmez, yalnız host tarafından zaten bırakılmış bir bağlantıya gider.
  - `MIGRATE_TIMEOUT_US` (3 s) el sıkışma + kanıt toplamını kapsar (taşıma isteğinden itibaren).
- **Test edilmeyenler / cihazda doğrulanacaklar (T-157 adım 7, orkestratör, tek seferde):**
  1. AUTO, Wi-Fi'de akış varken USB kablosu tak (adb reverse açık): logda sırayla `migrate_start`, `migration_proof_wait`, (Wi-Fi'de `bye_recv reason=5` ve/veya `migration_old_gone`), `migrate_switch`, `migration_proved`, `transport_migrate ok=1 reason=ok`; görüntü USB'de devam eder, tek `video_open`.
  2. Taşıma sırasında kalemle çizgi çizip/tuş basılı tutup bırak: Mac'te takılı tuş ya da kalem teması kalmamalı.
  3. Squatter benzetimi: `adb reverse --remove tcp:47001` ve tablette `127.0.0.1:47001`'i dinleyen bir test uygulaması yoksa yalnız `connect_failed` görülür; varsa (ör. sahte ack gönderen bir probe) `transport_migrate ok=0 reason=proof_*` ve Wi-Fi oturumu kesintisiz sürmeli, AUTO geri çekilmeli (aralık büyür).
  4. Gerçek bir taşıma sonrası `retired_close` bir kez ve hemen (STREAM_CONFIG ile) görülmeli.
  - Ayrıca: codex incelemesi (`./scripts/codex-review.sh main task/T-205-client-migration-auth-gate --high`) orkestratörde.
- **Açık sorular:**
  - `docs/LOGGING.md` eklemeleri (orkestratör): yeni olaylar `migration_proof_wait cand_gen=N`, `migration_old_gone how=bye|closed|pong_timeout`, `migration_proved cand_gen=N`; `transport_migrate reason=` için yeni değerler `proof_failed`, `proof_closed`, `proof_timeout`. Hiçbirinde host_id, anahtar ya da jeton yok.
  - PROTOCOL.md §3.3 metni istemcinin terfi sırasını anlatmıyor; tel değişmediği için dokunulmadı.
