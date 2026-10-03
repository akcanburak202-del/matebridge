---
id: T-152
title: Activate PAIRED sessions only after the first authenticated record
status: in-progress
phase: 6
owner: mac-host-dev
depends_on: [T-041]
decisions: []
files:
  - host-mac/Sources/MateBridgeCore/Session/SessionMachine.swift
  - host-mac/Tests/MateBridgeCoreTests/Session/
  - backlog/tasks/T-152-host-paired-proof-first.md
---

## Amaç

When no session is live, the Mac activates a PAIRED connection as soon as it sends its HELLO_ACK, before the peer has proved it holds the pair key. Anyone who has seen an approved tablet's `device_id` (sent in clear in HELLO) can therefore make the Mac create the virtual display, wake the displays and hold display sleep, every few seconds, indefinitely. This card applies the T-041 takeover proof rule to every PAIRED connection: the session starts, STREAM_CONFIG goes out and the display is built only after the first authenticated record. A real reconnect costs about one extra round trip.

Source: external architecture review 2026-10-03 (SE2, W3; A1 as a contract hole); verification: docs/reviews/2026-10-03/verify-A-security.md (additional issue A1, WI-3) and docs/reviews/2026-10-03/verify-A2-adversarial.md (§3).

## Bağlam

`HC/` = `host-mac/Sources/MateBridgeCore/`. Lines are at HEAD a30c769 and were re-checked.

- **Evidence:**
  - `HC/Session/SessionMachine.swift:607-614`: PAIRED is chosen from `approvedDevices.contains(deviceID)` plus the stored key; `device_id` is the only client selector and is cleartext.
  - `continueHello` PAIRED branch `:649-668`: with a slot owner of the same device → `takeover = true` → `.proving` (:660-665). With **no** slot owner → `start()` directly (:666-667). `start()` (:726-735) sets `.active`, sends STREAM_CONFIG and emits `.sessionStarted` without any authenticated record.
  - `prove()` (:696-716) already handles "no slot owner" structurally (the supersede block is inside `if let owner = slotOwner`), then calls `start()` and processes the first record after activation (:713-714). It needs a test for the no-owner case, not a rewrite.
  - Side effects of `.sessionStarted` (`host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift:307-328`): sleep gate opens ("awake reason=session_started"), `displaySleep.hold()`, and `lease.sessionStarted` → display create (`HC/Video/DisplayLease.swift:37-47`) with attacker-chosen HELLO screen fields, i.e. display churn and window rearrangement. The attacker's session dies at the first bad record or after `closeSilenceUs` = 5 s (`SessionMachine.swift:85`), but the 10 s lease grace (`DisplayLease.swift:9`) means one HELLO every 5–10 s keeps a display alive and other devices get BUSY.
  - Bound: `awaitingHelloCount` already counts `.proving` (`SessionMachine.swift:220-228`), and `SessionServer` refuses new connections at `maxUnauthenticated = 4` (`host-mac/Sources/MateBridgeHost/Session/SessionServer.swift:304`, `:1127-1132`, `:1182-1187`). Today a non-takeover PAIRED connection skips that bound because it goes straight to `.active`.
  - The client already sends the proof PING first after ACCEPTED (`client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionMachine.kt:306`), then STREAM_PREFS (T-050), so no client change is needed.
- **Exposure:** none (verified by A2 §3): no input, video, clipboard or files without `pair_key`. This is an availability/power fix (Low/Medium).
- **Plan hints:** route both PAIRED cases through `.proving` with `proofTimeoutUs` (5 s, `:109`); the proving-deadline handling in `tick` (:500) closes an unproved connection. Keep the takeover path's behaviour and logs (`takeover_proving`) unchanged; add a distinct log reason for the non-takeover case only if useful (e.g. `paired_proving takeover=0`), listed under *Açık sorular* for `docs/LOGGING.md`.
- **PROTOCOL.md (orchestrator, before or at merge; prose only):** §3 step 3: "host her PAIRED bağlantıda ilk doğrulanmış kaydı bekler, sonra etkinleştirir ve STREAM_CONFIG gönderir". No message or fixture change.
- **Interaction with T-150:** none on the wire. A locally untrusted client (T-150) still sends PING, so the host proves and activates as usual.
- **Interaction with T-156:** after this card a wrong client key is never seen by the client as `AUTH_FAILED` on a host record: the host sends no record before the proof and closes **without BYE** at the bad proof (`recordAuthFailed`, `SessionMachine.swift:275-277`). T-156 counts that case (close after the proof PING, before any authenticated host record).
- **Known window (documented, not fixed):** `.proving` is not a slot owner (`slotOwner`, `SessionMachine.swift:575-580`). During a non-takeover proof (about 1 RTT) a PAIRING HELLO from another device can take the slot as pending, and the proving tablet is then answered BUSY at the proof (`prove()` :698-708). The window is tiny and the exposure already exists in no-session gaps; the test below pins the outcome.
- **Serialize with:** T-155 and T-171 (same file `SessionMachine.swift`; chain T-152 → T-155 → T-171). Host PING (T-171) must start only after activation.
- **Review:** security change: the orchestrator runs `./scripts/codex-review.sh`.

## Kapsam dışı

- Client changes; display-lease grace tuning (D4); USB-only listening (T-189); the orphan-approval guard (T-155).

## Kabul kriterleri

- [ ] [XCTest] Non-takeover PAIRED with no record: no `.sessionStarted`, no `.send(streamConfig)`; the connection is closed at `proofTimeoutUs`.
- [ ] [XCTest] Non-takeover PAIRED + a valid encrypted PING: `.sessionStarted`, then STREAM_CONFIG, then the pong for that PING, in that order.
- [ ] [XCTest] Non-takeover PAIRED + a record that fails authentication: closed, no `.sessionStarted`, no display-related action.
- [ ] [XCTest] Proving connections count toward the unauthenticated bound (`awaitingHelloCount`, `maxUnauthenticated` = 4).
- [ ] [XCTest] PAIRING HELLO from device B while device A's non-takeover PAIRED connection is proving: the outcome is pinned by a test and described in Handoff (expected today: B pending, A gets BUSY at its proof).
- [ ] [XCTest] Existing takeover and orphan tests pass unchanged.
- [ ] [device] A normal reconnect still shows video (about +1 RTT); `session_started` follows the first record in `host.log`.
- [ ] The orchestrator ran `./scripts/codex-review.sh` and its findings are resolved or recorded.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

1. `SessionMachine.continueHello`: PAIRED dalında devralma olsun olmasın bağlantı `.proving` (son tarih `proofTimeoutUs`) durumuna geçer; `start()` artık yalnız `prove()` içinden (ve PAIRING'de `pairingPersisted`'dan) çağrılır. Devralma logu `takeover_proving` aynen kalır; devralmasız durum için `ev=paired_proving` (LOGGING.md için *Açık sorular*).
2. `prove()` zaten yuva sahibi yokken doğru çalışıyor (supersede bloğu `if let owner` içinde): yalnız doc yorumu güncellenir, mantık değişmez.
3. Testler (`Tests/MateBridgeCoreTests/Session/`): `SessionMachineTests`'teki `activate` yardımcısı HELLO'dan sonra kanıt PING'i de gönderir (aktif oturum isteyen eski testler aynen kalır); yeni `PairedProofFirstTests.swift`: kayıtsız zaman aşımı, PING ile sıra, doğrulanamayan kayıt, `awaitingHelloCount` sınırı, kanıt sırasında B'nin PAIRING HELLO'su.
4. Risk: mevcut testlerin bir kısmı PAIRED HELLO'dan hemen sonra aktif oturum bekliyor; bunlar kart kapsamı dışındaki dosyalardaysa (ör. `Tests/.../Crypto/`) durup *Açık sorular*'a yazılır.

## Handoff

**Durum: ENGELLİ (status `in-progress`, `review` değil).** Kod ve kapsam içi testler hazır, ama `./scripts/check.sh` kırmızı: kart dışındaki iki test dosyası PAIRED HELLO'dan hemen sonra aktif oturum bekliyor (bkz. *Açık sorular* 1). Kural gereği o dosyalara dokunmadım.

- **Commit:** `07772bc` (kod + Session testleri), plan `1fdac26`. Dal `task/T-152-host-paired-proof-first`.
- **Dokunulan dosyalar:**
  - `host-mac/Sources/MateBridgeCore/Session/SessionMachine.swift`: `continueHello` PAIRED dalı devralma olsun olmasın `.proving(proofTimeoutUs)`; `start()` artık yalnız `prove()` ve `pairingPersisted` içinden. Devralmasız durumda `ev=paired_proving`, devralmada `ev=takeover_proving` (değişmedi). `prove()` mantığı değişmedi, yalnız doc yorumları.
  - `host-mac/Tests/MateBridgeCoreTests/Session/PairedProofFirstTests.swift` (yeni, 9 test, gerçek şifreli kayıtlı küçük bir tel düzeneğiyle).
  - `Session/SessionMachineTests.swift`: `activate` yardımcısı HELLO'dan sonra kanıt PING'i gönderir; doğrudan HELLO ile aktif oturum bekleyen 6 test kurulumuna tek satır kanıt PING'i eklendi (`approvedDeviceIsAcceptedWithConfig` artık STREAM_CONFIG'i kanıttan sonra bekliyor). Devralma testlerinin gövdeleri aynı; yalnız `takeoverNeedingPairingIsBusy` kurulumuna A'nın kanıtı eklendi.
  - `Session/PairingOrphanApprovalTests.swift`: `afterAnOrphanApprovalTheReconnectIsPairedWithThatKey` HELLO'dan sonra `idle`, kanıt PING'inden sonra `active` bekliyor (kaçınılmaz: davranış değişikliği bu).
  - `Session/ControlSocketTests.swift`: test tableti `handshake()`'te ACCEPTED'dan sonra kanıt PING'i gönderip PONG'u bekliyor (gerçek istemci gibi).
- **Kabul kriterleri (XCTest):**
  - Kayıtsız PAIRED: `sessionStarted`/STREAM_CONFIG yok, `proofTimeoutUs`'te `close` + `proof_timeout`, anahtarlar silinir → `withoutARecordNothingStarts...`.
  - Geçerli şifreli PING: sıra **STREAM_CONFIG gönderimi → `sessionStarted` → PONG** (kartta "sessionStarted, sonra STREAM_CONFIG" yazıyor; `start()`'ın mevcut sırasını korudum, çünkü devralma ve PAIRING kabulü de aynı yolu kullanıyor ve devralma testleri "değişmeden" geçmeli. İkisi de PONG'dan önce; istemci telde STREAM_CONFIG, PONG görür) → `aValidSealedPing...`.
  - Doğrulanamayan ilk kayıt (bozuk etiket ve başka pair key): kapat, BYE yok, `sessionStarted`/`sessionEnded`/`releaseInput`/`deliver`/STREAM_CONFIG yok → `aRecordThatFailsAuthentication...`, `aRecordUnderAnotherPairKey...`.
  - Sınır: 4 onaylı cihazın 4 kanıtsız PAIRED bağlantısı `awaitingHelloCount == 4` (SessionServer `maxUnauthenticated = 4` 5.'yi reddeder; sabit Host hedefinde, Core testinden erişilemiyor, testte değer yazılı) → `provingConnectionsCountTowardTheUnauthenticatedBound`.
  - Kanıt sırasında B'nin PAIRING HELLO'su: **B pending olur (onay penceresi açılır), A kanıtında `BUSY` + kapanır, B'nin isteği iptal edilmez, A'nın anahtarları silinir** → `aPairingHelloFromAnotherDevice...`.
  - Ek: kanıtsız bağlantı düşerse iz bırakmaz; aynı cihazın iki kanıtsız bağlantısında ilk kanıtlayan başlar, ikincisinin kanıtı normal devralma (SUPERSEDED); canlı oturumdayken log `takeover_proving` olarak kalır.
- **check.sh:** KIRMIZI. Swift: 700 testten 16'sı düşüyor, hepsi kart dışındaki `Tests/MateBridgeCoreTests/Crypto/` altında (aşağıda). Diğer her şey (Session/, Input/ dahil) yeşil.
- **Varsayımlar:** İstemci değişikliği gerekmiyor: Kotlin `onAck(ACCEPTED)` ilk olarak PING gönderiyor (`SessionMachine.kt` ~:306), sonra STREAM_PREFS. Video bağlantısı STREAM_CONFIG'ten sonra açıldığı için kanıttan önce açılamaz. `SessionServer` eylem güdümlü; `.sessionStarted` zaten devralma yolunda kanıttan sonra geliyordu, Host kodu değişmedi.
- **Test edilmeyenler / cihazda doğrulanacaklar:**
  - Gerçek yeniden bağlanmada video geliyor mu (≈ +1 RTT); `host.log`'da `handshake mode=paired` → `paired_proving` → `session_started` sırası.
  - USB ve Wi-Fi'de bağlantı kurulum süresi (gözle fark edilmemeli).
  - Yanlış anahtarlı tablet (T-156 durumu): host kanıtta BYE'sız kapatıyor; istemcinin bunu nasıl gösterdiği.
- **Açık sorular:**
  1. **Kapsam (ENGEL):** Şu iki dosya kart `files:` listesinde değil ama davranış değişikliği yüzünden güncellenmeli: `host-mac/Tests/MateBridgeCoreTests/Crypto/SessionCryptoTests.swift` (11 test: `pairedHandshakeAgrees...`, `unauthenticatedBytesAfterTheHandshake...`, `tamperedRecordCloses...`, `secondConnectionAfterPairing...`, `busyIsPlaintext...`, `invalidPublicKey...`, `realClientProves...`, `prkIsWipedWhenTheProvingTakeoverIsDiscarded`, `takeoverWipesTheOldSessionsPrk`, `videoKeysDerive...`, `aReplayedVideoNonce...`) ve `host-mac/Tests/MateBridgeCoreTests/Crypto/KeychainAsyncTests.swift` (5 test: `aPendingLookupSendsNothing...`, `aLookupThatIsStillPending...`, `otherDeviceIsBusyWithoutALookup`, `theSlotIsRechecksAfterTheLookupReturns`, `anUnprovenTakeoverNeverTouches...`). Hepsi mekanik: canlı oturum kurulumunda PAIRED HELLO / `pairKeyResolved`'dan sonra bir kanıt PING'i. İki istisna: `unauthenticatedBytes...` ve `tamperedRecord...` ilk kaydın bozuk olduğu durumda release-all/`sessionEnded` bekliyor; artık ilk kayıt bozuksa ortada oturum yok (yeni testler bunu sabitliyor), bu yüzden bozuk kayıttan önce geçerli bir kanıt PING'i eklenmeli. `theSlotIsRechecks...`'te B'nin kanıtı A'nın cevabından önce eklenmeli ki A yine BUSY alsın (yoksa ikisi de proving olur ve ilk kanıtlayan kazanır). Öneri: `files:`'a `host-mac/Tests/MateBridgeCoreTests/Crypto/` eklenip aynı dalda devam.
  2. **LOGGING.md:** yeni olay `ev=paired_proving conn=N` (info, alan yok), devralmasız PAIRED bağlantı kanıt bekliyor. `proof_timeout` artık devralmasız bağlantılar için de çıkar.
  3. **PROTOCOL.md §3 adım 3** (orkestratör): "host her PAIRED bağlantıda ilk doğrulanmış kaydı bekler, sonra etkinleştirir ve STREAM_CONFIG gönderir".
