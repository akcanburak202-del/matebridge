---
id: T-337
title: Host — 0038 protokol kodu (STREAM_PREFS link/fps/taban, AUDIO_* ayrıştırma) ve uzak profil davranışı
status: review
phase: 7
owner: mac-host-dev
depends_on: [T-336]
decisions: [0038]
files:
  - host-mac/Sources/MateBridgeCore/
  - host-mac/Sources/MateBridgeHost/Session/
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeHost/Cursor/
  - host-mac/Sources/MateBridgeHost/Files/
  - host-mac/Tests/
  - docs/KNOBS.md
  - backlog/tasks/T-337-host-remote-profile.md
---

## Amaç

Karar 0038 §3 ve PROTOCOL.md'deki yeni kuralların host tarafı. Dal tabanı: `task/0038-remote-integration` (main değil).

## Kapsam

1. **Protokol kodu (Swift):**
   - STREAM_PREFS: fps `15`/`30` desteklenir; kullanıcı bit hızı aralığı `500`–`150000` (`StreamPrefsPolicy`, `VideoSettings` env knob, `BitrateRequest.defaultRange` birlikte); üçüncü isteğe bağlı grup `link` + `reserved` (16 bayt; 15 bayt protokol hatası).
   - AUDIO_PREFS `codec` alanı (ayrıştırma + kodlama), AUDIO_CONFIG `format = 2` sabiti, AUDIO_FRAME `frame_count` sınırı 1–1024, HELLO bit14 `AUDIO_AAC` sabiti. **AAC kodlama bu kartta yok** (T-340); host bu kartta her zaman PCM gönderir.
   - Yeni fixture'ların hepsi için decode/encode testleri (`everyFixtureFileHasATestCase` geçmeli).
2. **15/30 fps:** sanal ekran 60 Hz kalır; `FrameGate` ve yakalama aralığı bu hızlarda doğru seyreltir. Varsayılan bit hızı formülü (`defaultBitrateKbps`) düşük fps'te taban 20 Mbps'e takılmamalı mı? Uzak profil her zaman bit hızı gönderdiği için formül değişmeyebilir; karar planda gerekçeyle yazılsın.
3. **`link = 1` davranışı (oturum başına, son STREAM_PREFS):**
   - host kontrol PING'i 2 sn; heartbeat kapanışı 15 sn; 1,5 sn release-all **değişmez**;
   - `CURSOR_STATE` canlılık aralığı 2 sn;
   - netleştirme treni bütçesi ve video soketi düşük su işareti = hedef bit hızının 250 ms'si, en az 16 KB;
   - `FILES_NET OPEN` gönderilmez (açıksa kapatılır);
   - tercih T-049 cihaz deposuna yazılmaz.
4. Loglar: `ev=stream_prefs ... link=1` gibi tek satır; LOGGING.md biçimi.

## Güvenlik kuralı (AGENTS.md)

Heartbeat değişikliği takılı girdi yaratmamalı: release-all 1,5 sn'de kalır. Testle doğrula: `link = 1` iken 1,5 sn sessizlikte tutulan tuş bırakılır, bağlantı 15 sn'ye kadar açık kalır.

## Kabul

- `./scripts/check.sh` Swift kısmı geçer (Kotlin kısmı T-339'a kadar fixture kapsamında düşebilir; handoff'ta yaz).
- Birim testleri: STREAM_PREFS 8/12/14/16 bayt ve 15 bayt hatası; fps 15/30 kabul, 45 → 60; bit hızı 400 → 500, 1000 → 1000; link=1 zamanlamaları; T-049 deposuna yazılmaz; FILES_NET OPEN bastırılır.
- Cihaz testi orkestratörde (uzak oturum, T-339 ile birlikte).

## Plan

1. **Core protokol:** `StreamPrefs` + `link`/`linkReserved` (3. grup, yalniz `link != 0` iken yazilir, 15 bayt hata); `supportedFps` 15/30 eklenir; `normalized` link'i 0/1'e indirir. `AudioPrefs.codec` (0/1, digeri 0), `AudioFormat.aacLC = 2`, `AudioFrame` siniri 1...1024 (`ProtocolConstants.audioMaxFrames`), `Capabilities.audioAAC` (bit14). Host bu kartta PCM gonderir.
2. **Bit hizi araligi 500...150000:** `VideoSettings.userBitrateRangeKbps` (-> `BitrateRequest.defaultRange` otomatik), `parseBitrateKbps` env knob'u, KNOBS satiri 24.
3. **15/30 fps:** sanal ekran 60 Hz kalir (`displayRefreshHz` zaten <120 icin 60). `FramePacer`/`FrameGate` fps'ten aralik turetir; testle 60 Hz kaynaktan 15 ve 30 fps ortalamasi dogrulanir. `defaultBitrateKbps` formulu DEGISMEZ: uzak profil her zaman bit hizi gonderir (`bitrate_kbps != 0`), formul yalniz `0` icin kullanilir; 15/30 fps gonderen ama bit hizi `0` gonderen bir istemci yoktur, o halde 20 Mbps tabani eski davranisi korur (gerekce handoff'ta).
4. **`link = 1` (`RemoteLinkProfile`, Core, saf):** host PING 2 sn, kapanis 15 sn (`releaseSilenceUs` 1,5 sn degismez), `CURSOR_STATE` keep-alive 2 sn, netlestirme treni butcesi ve video soketi `TCP_NOTSENT_LOWAT` = hedef bit hizinin 250 ms'si (en az 16 KB). `SessionMachine` aktif baglantida son STREAM_PREFS'ten `link` tutar (STREAM_PREFS'e kadar normal; oturum basina). `CursorStreamPlanner` keep-alive degistirilebilir. `StillRefineConfig.resolve` link+bit hizi alir (`MATEBRIDGE_REFINE_KB` env hala kazanir). `BsdTcpConnection.setNotSentLowat` canli ayar; `SessionServer` video soketlerine uygular. `StreamCoordinator`: `prefsStore.save` link=1 iken atlanir, refine butcesi icin oturum link'i. `TabletFilesPlanner.linkChanged(remote:)`: `FILES_NET OPEN` verilmez, aciksa `CLOSE` + teardown, menu gizli.
5. **Testler:** mesaj kodek (8/12/14/16 bayt, 15 bayt hata, 9-11/13), fixture'lar (`everyFixtureFileHasATestCase`), ses codec/frame_count, fps/bit hizi normalizasyonu, link zamanlamalari (1,5 sn release / 15 sn kapanis), planner keep-alive, refine butcesi, lowat hesabi, T-049 deposuna yazilmama (saf politika `RemoteLinkProfile.persistsPrefs`), FILES_NET suppress.
6. Log: `ev=stream_prefs ... link=1`.

## Handoff

- **Commit:** `git log -1 task/T-337-host-remote-profile`; dal `task/T-337-host-remote-profile`, taban 729f60c3.
- **check.sh:** Swift kismi tam gecti (swift test: 684 XCTest + 1141 Swift Testing; fixture, crypto, measurement kit OK). Gradle kismi **beklenen sekilde 1 test dusuyor** (Kotlin fixture-kapsama testi, yeni 6 fixture icin; T-339 gelene kadar).
- **Dosyalar:** Core: `Messages.swift` (StreamPrefs.link, fps 15/30, `Capabilities.audioAAC`), `Protocol/AudioMessages.swift` (`AudioPrefs.codecWire/codec`, `AudioFormat.aacLC`, `AudioCodecPreference`), `ProtocolConstants.swift` (frame_count 1024), `Video/StreamPrefsPolicy.swift` + `VideoSettings.swift` (500 kbps taban, env knob), `Video/StillRefine.swift` (uzak butce), `Session/RemoteLinkProfile.swift` (yeni; saf sabitler/hesap), `Session/SessionMachine.swift` (oturum basina `remote`; 15 sn kapanis, 2 sn host PING), `Session/BsdTcpSocket.swift` (`setNotSentLowat`), `Cursor/CursorStreamPlanner.swift` (2 sn keep-alive), `Files/TabletFilesPlanner.swift` (`linkChanged`). Host: `Session/SessionServer.swift` (link yonlendirme, video soketi lowat), `Session/StreamCoordinator.swift` (T-049 deposuna yazmama, refine butcesi, `link=` logu), `Cursor/CursorService.swift`, `Files/TabletFilesBridge.swift`. Testler: yeni `Tests/MateBridgeCoreTests/Session/RemoteLinkTests.swift`; fixture/codec/ses testleri ve eski 5000/960/payload-kuyrugu testleri guncellendi. `docs/KNOBS.md` satir 24 ve 36.
- **Varsayimlar / kararlar:**
  - `defaultBitrateKbps` formulu degismedi: uzak profil her zaman bit hizi gonderir (`bitrate_kbps != 0`), formul yalniz `0` icin kullanilir; test 15 fps + 0 -> 20 Mbps tabanini sabitler.
  - 15/30 fps icin `FramePacer`/`FrameGate` degismedi; testle 2xfps ve 60 Hz kaynaktan ortalama hiz fps'e esit dogrulandi. SCK `minimumFrameInterval` 1/(2 fps) kaldi.
  - Eski testlerde 14 bayttan sonraki "kuyruk" baytlari artik link grubu oldugu icin (16 bayt) o testler kuyrugu 16 bayttan sonraya tasidi (protokol degisikliginin dogal sonucu).
  - `link` yalniz aktif baglantida ve son STREAM_PREFS'ten alinir; yeni oturum `remote=false` ile baslar. Ilk host PING hala hemen gider, sonraki aralik o ana kadarki `remote`'a gore.
  - Refine butcesi ve video soketi lowat'inda gelistirici env'i (`MATEBRIDGE_REFINE_KB`, `MATEBRIDGE_NOTSENT_LOWAT_KB`) uzak profile kazanir.
  - Refine butcesi `createPipeline`'da okunur: yalniz `link` degisip ayar degismeyen bir STREAM_PREFS boru hattini yeniden kurmaz (uzak profilde fps/ekran farkli oldugundan pratikte hep kurulur). Video lowat canli ayarlanir (yeni video baglantisi ve STREAM_CONFIG bit hizi degisince).
  - Dosyalar: uzak oturumda menu gizli; acik Wi-Fi paylasim `FILES_NET(CLOSE)` + unmount + proxy durdurma ile kapanir; normal linke donunce tekrar sunulur.
  - AAC kodlama yok (T-340); `AudioPrefs.codec` yalniz ayristirilir/kodlanir, host PCM gondermeye devam eder.
  - `StreamPrefsStorageCodec` link yazmaz/okumaz.
- **Gercek donanimda dogrulanacak (test edilmedi):** uzak oturumda `TCP_NOTSENT_LOWAT`'in canli degisimi (setsockopt aktif soketlerde isler mi), 15 fps ScreenCapture teslimati ve seyreltme, 1400x920 sanal ekran + 1 Mbps, 15 sn kapanis + 1,5 sn release-all birlikte, Wi-Fi paylasimin uzak linke gecince kapanmasi, `ev=stream_prefs ... link=1` logu. `SessionServer`/`StreamCoordinator`/`TabletFilesBridge` yonlendirmesinin birim testi yok (saf mantik Core'da test edildi). Cihaz testi orkestratorde (T-339 ile).
- **Dokunulmayanlar:** `MateBridgeApp/main.swift` (gerek olmadi: `handlers.deliver` zaten tum mesajlari bridge'e verir) ve PROTOCOL.md.

## Open questions

### Codex review fixes (2026-10-11)

- P2-1: `link` updates are coalesced per session (latest value + one pending drain, `EpochCoalescer`) in `CursorService.link` and `TabletFilesBridge.deliver`; a session boundary voids the slot.
- P2-2: `StreamCoordinator.applyPrefs` now adjusts the refine ceiling live (`VideoPipeline.setRefineMaxBytes` -> `HEVCEncoder` -> `StillRefinePolicy.setMaxBytes`) before the settings-equality guard: no rebuild, no new config_id. The video socket low-water was already applied live from `SessionServer.linkChanged` independent of settings. Tests: `refineCeilingChangesLiveOnARunningPolicy`, `linkUpdatesCoalesceToTheNewestValue`.
- Note: `StallRestartTests.retryJoinsTheHangingReleaseAndRestartsOnceItCompletes` (unrelated, 50 ms timeouts) failed once under full-suite load, passes alone and in check.sh.
