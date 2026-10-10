---
id: T-339
title: İstemci — 0038 protokol kodu, "Uzaktan bağlan" düğmesi, uzak profil ve keyframe yineleme geri çekilmesi
status: review
phase: 7
owner: android-client-dev
depends_on: [T-336]
decisions: [0038, 0030, 0036, 0035]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/
  - client-android/app/src/main/res/
  - client-android/app/src/test/
  - backlog/tasks/T-339-client-remote-connect.md
---

## Amaç

Karar 0038 §1, §2, §6, §7 ve ekleri; PROTOCOL.md yeni kurallarının istemci tarafı. Dal tabanı: `task/0038-remote-integration` (main değil).

## Kapsam

1. **Protokol kodu (Kotlin):** STREAM_PREFS bağlantı grubu (16 bayt yazma kuralı, 15 bayt hata), AUDIO_PREFS `codec`, AUDIO_CONFIG `format = 2` sabiti, AUDIO_FRAME 1–1024 sınırı, HELLO bit14 sabiti (**bu kartta bildirilmez**; AAC çözücüsü T-341). Yeni fixture'ların hepsi için testler.
2. **"Uzaktan bağlan":** bağlantı ekranında ayrı düğme. Uzak adres ayrı saklanır (IPv4 ya da DNS adı, sondaki nokta atılır, isteğe bağlı `:port`, varsayılan 47001; IPv6 yok). İlk kullanımda sorulur, düzenlenebilir. Uygulama açılışında uzak adrese kendiliğinden bağlanılmaz; uzak oturum koparsa aynı adrese normal geri çekilmeyle yeniden bağlanılır.
3. **Uzak profil (yalnız bu düğmeyle kurulan oturum):** STREAM_PREFS `link = 1`, `fps = 15`, `display_* = 1400×920`, SDR, `chroma = 0`, uzak bit hızı (0,5 / 1 / 2 Mbps, varsayılan 1, ayrı hatırlanır). Yerel imleç açık. Uzak ses ayarı ayrı, varsayılan **kapalı** (açılınca bu kartta PCM istenir; T-341 AAC'ye çevirir). `FILES_INFO` OFF. WoL yok. Mod seçimi ve Ctrl+Shift+7 etkisiz; panel "Uzak (Tasarruf)" gösterir; kullanıcının normal mod/ayarları değişmez.
4. **Zamanlamalar (uzak oturum):** PING 500 ms (girdi tutuluyorken ya da son girdiden 2 sn içinde) / 2 sn (boşta); PONG zaman aşımı 10 sn; STATS 5 sn; yerel imleç zaman aşımı 5 sn.
5. **Ağ değişimi:** uzak oturumda otomatik USB/Wi-Fi geçişi ve ağ geri çağrıları oturumu düşürmez ya da başka yola geçirmez (etkin ağ VPN ya da mobil veri olabilir).
6. **Reddedilen uzak eşleşme:** uzak oturumda REJECTED → "Yeni eşleşme yalnız ev ağında ya da USB ile yapılabilir." Giriş ekranında kalır, yeniden denemez.
7. **Tüm oturumlar:** keyframe beklerken STARTUP yinelemesi 500 ms → iki katına, en çok 4 sn; keyframe gelince sıfırlanır (`FrameQueue`/`MainActivity` `KEYFRAME_RETRY_MS`).

## Güvenlik kuralı (AGENTS.md)

PING seyreltme takılı girdi yaratmamalı: herhangi bir tuş/düğme/kalem/açık hareket varken PING 500 ms'de kalır; ilk girdi olayı hızlı aralığa hemen döner. Birim testiyle doğrula.

## Kabul

- Birim testleri: STREAM_PREFS uzak 16 bayt = `stream_prefs_remote`; normal oturum baytları değişmez; PING aralık seçimi; STARTUP geri çekilme dizisi 500/1000/2000/4000/4000; adres ayrıştırma; uzak ses varsayılan kapalı.
- `./scripts/check.sh` Kotlin kısmı geçer (Swift kısmı T-337'ye kadar fixture kapsamında düşebilir; handoff'ta yaz).
- Cihaz testi orkestratörde.

## Plan

1. **Protokol (Kotlin):** `StreamPrefs.link` (16 bayt yazma, 15 bayt SHORT_PAYLOAD), `AudioPrefs.codec`, `AudioConfig.FORMAT_AAC_LC`, `AudioFrame.MAX_FRAMES = 1024`, `Capabilities.AUDIO_AAC` (sabit; HELLO'da bildirilmez). `FixtureTest` yeni fixture'lar + `CodecRulesTest`/`AudioCodecTest` ek testleri.
2. **Saf mantık:** `RemoteProfile` (uzak STREAM_PREFS/AUDIO_PREFS), `RemoteTimings` (PING 500 ms/2 sn seçimi, PONG 10 sn, STATS 5 sn, imleç 5 sn), `RemoteAddress.parse`, `KeyframeRetryBackoff` (500/1000/2000/4000/4000). Hepsi JVM testli.
3. **SessionMachine/Controller:** `Event.Start.remote: RemoteProfile?`. Uzak oturumda STREAM_PREFS/AUDIO_PREFS profilden gider, normal `SetPrefs`/`SetAudio` yalnız saklanır (kullanıcının normal ayarı değişmez); `FILES_INFO` OFF; PING `RemoteTimings` + `inputActive` (InputCapture'ın yayımladığı tutulu girdi / son girdi), PONG zaman aşımı 10 sn; uzak oturumda migrasyon reddedilir. Yeni `SetRemote` olayı (panelden bit hızı/ses).
4. **FrameQueue:** STARTUP yinelemesi `KeyframeRetryBackoff` ile (tüm oturumlar).
5. **MainActivity/UI:** ayrı "Uzaktan bağlan" + "Uzak adres" düğmesi, uzak adres/bit hızı/ses `Settings`'te ayrı; uzak oturumda WoL, keşif, otomatik USB/Wi-Fi geçişi, yeniden keşif, dosya sunucusu kapalı; mod seçimi/Ctrl+Shift+7 etkisiz, panel "Uzak (Tasarruf)"; STATS 5 sn; yerel imleç zaman aşımı 5 sn; REJECTED -> uzak eşleşme metni.
6. Testler: STREAM_PREFS uzak baytları, PING aralığı + takılı girdi güvenliği (makine testi), STARTUP geri çekilme dizisi, adres ayrıştırma, uzak ses varsayılan kapalı.

## Handoff

**Commit:** `git log task/T-339-client-remote-connect` (son commit "T-339: client remote connect ..."; plan commit e2bc8890). Taban 729f60c3.

**check.sh:** `./scripts/check.sh --only android,protocol` -> ALL OK (Kotlin birim testleri, fixture `gen.py --check`, crypto vektörleri). Tam `check.sh` bu tabanda Swift fixture-kapsam testinde T-337'ye kadar düşer (beklenen); Swift çalıştırılmadı.

**Dokunulan dosyalar**
- Protokol: `protocol/Messages.kt` (`StreamPrefs.link`, `AudioPrefs.codec`, `AudioConfig.FORMAT_AAC_LC`, `AudioFrame.MAX_FRAMES=1024`, `Capabilities.AUDIO_AAC` sabiti; HELLO'da BİLDİRİLMİYOR), `protocol/Codec.kt`.
- Yeni: `session/RemoteProfile.kt` (RemoteProfile, RemoteTimings, RemoteUi), `session/RemoteAddress.kt`, `video/KeyframeRetryBackoff.kt`.
- `session/SessionMachine.kt` (Start.remote, SetRemote, uzak PING/PONG, FILES_INFO OFF, migrasyon reddi), `SessionController.kt`, `Latest.kt` (mail.remote), `Settings.kt` (uzak adres/bit hızı/ses ayrı anahtarlar), `TrustUiText.kt` (`ConnectOrigin.REMOTE`).
- `video/FrameQueue.kt` (STARTUP yineleme geri çekilmesi, tüm oturumlar), `input/InputCapture.kt` (`holdsInput`/`lastInputUs` yayını), `cursor/CursorPrefsPolicy.kt` (uzakta 5 sn, uzakta her zaman yerel imleç), `settings/SettingsCatalog.kt`, `MainActivity.kt`, `res/layout/activity_main.xml`, `res/values/strings.xml`.
- Testler: FixtureTest (6 yeni fixture), CodecRulesTest, AudioCodecTest, SettingsResetTest/SettingsCatalogTest (güncellendi), yeni `RemoteSessionMachineTest`, `KeyframeRetryBackoffTest`, `HeldInputSignalTest`.

**Tasarım**
- Uzak oturum = `SessionController.start(..., remote = RemoteProfile)`; makine profili STREAM_PREFS/AUDIO_PREFS olarak yollar (`link=1`, 15 fps, 1400x920, SDR, chroma 0, bit hızı 0,5/1/2 Mbps varsayılan 1, ses varsayılan KAPALI). Normal `SetPrefs`/`SetAudio` uzak oturumda yalnız saklanır (normal ayarlar değişmez, sonraki normal oturum onlarla açılır). Panelden bit hızı/ses -> `SetRemote`.
- PING (uzak): `RemoteTimings.pingDue` son gerçekten giden PING'e göre; girdi tutuluyor ya da son girdiden <2 sn -> 500 ms, değilse 2 sn. İlk girdi hızlı aralığı anında geri getirir. Tutulu girdi `InputCapture.holdsInput` (tuş/düğme/kalem teması+yakınlığı/açık dokunma-scroll-pinch), UI iş parçacığında her olay ve tick'te yayımlanır; birim testleri var (60 sn tutulan girdi, en büyük PING aralığı <= 600 ms). PONG zaman aşımı 10 sn, STATS 5 sn (`statsIntervalMs`), imleç zaman aşımı 5 sn.
- Uzak oturumda kapatılanlar: WoL (planner `userDisconnected` gibi), keşif/yeniden keşif, USB probu, AUTO geçişi/fallback, migrasyon, tablet dosya sunucusu (`syncFiles` share=false + makine FILES_INFO OFF), mod seçimi ve Ctrl+Shift+7 (toast); uzak adres `lastWifiEndpoint`'e yazılmaz. Uygulama açılışında (`onStart`) uzak oturum kapanır, kendiliğinden bağlanmaz. Uzak oturum kopunca makinenin normal geri çekilmesi aynı adrese yeniden bağlanır.
- REJECTED / PAIRING-benzeri durumlar (uzak): "Yeni eşleşme yalnız ev ağında ya da USB ile yapılabilir." Giriş ekranında kalır, yeniden denenmez, güven düğmeleri gösterilmez.
- Günlükte uzak adres yoktur (`session_start host=remote`).
- Yeni UI: bağlantı ekranında "Uzaktan bağlan" ve "Uzak adres" düğmeleri + gizli/pasif `remote_endpoint` alanı (HiWrite kuralı: görünür düzenlenebilir alan yok, akış başlayınca gizlenir). İlk kullanımda alan açılır, adres yazılıp tekrar "Uzaktan bağlan" (ya da klavye Bitti) ile kaydedilir ve bağlanılır. Panel: "Görüntü modu: Uzak (Tasarruf)", uzak bit hızı satırı, "Ses (uzak oturum)".

**Varsayımlar**
- Uzak başlatma `userInitiated=false` (uzak yolda eşleşme başlatılmaz); tamamlanmamış bir eşleşme varsa makine StoredTrust gösterir -> uzakta aynı "eşleşme yalnız ev ağında" mesajı.
- `RemoteAddress`: küçük harfe çevirir, sondaki noktayı atar, IPv6 ve alt çizgili ad reddedilir.
- STATS 5 sn: istatistik penceresi/günlük (`statsTick`) de uzak oturumda 5 sn'lik pencerelerle çalışır (`r.onSkipWindow` 5 sn'lik skip yüzdesi alır).
- `Capabilities.AUDIO_AAC` tanımlı ama `buildHello`'ya eklenmedi (T-341).
- Tam `AUDIO_FRAME` AAC (1024 kare) paketleri bu kartta çalınmaz (PCM yolu `data_len` uyuşmazlığında atar); uzak ses PCM ister.

**Yapılmadı / test edilmedi**
- Kararın §6 son maddesi "oynatma başlangıç tamponu uzak oturumda ses için en az 100 ms" kart kapsam listesinde yok; uygulanmadı (T-341 ile birlikte düşünülmeli).
- Cihaz testi yok. Swift tarafı çalıştırılmadı.

**Tablette kontrol listesi (orkestratör)**
1. Normal bağlantı (USB/Wi-Fi/Bonjour) önceki gibi: STREAM_PREFS 8/12/14 bayt, davranış değişmedi; kalem/klavye/PING bozulmadı.
2. "Uzaktan bağlan": ilk basış adres alanını açar; Tailscale adresiyle bağlanınca host log'unda `link=1`, sanal ekran 1400x920, 15 fps, 1 Mbps; panelde "Uzak (Tasarruf)"; Ctrl+Shift+7 etkisiz; bağlantı bitince evdeki ayarlar bozulmamış.
3. Uzak oturumda bir tuşu/kalemi basılı tut: 10+ sn basılı kalsın, host 1,5 sn release-all'ı tetiklememeli (PING 500 ms). Boştayken PING 2 sn.
4. Wi-Fi/mobil veri geçişinde (uzak) oturum başka yola geçmemeli; USB takılınca AUTO geçişi uzak oturumu etkilemez.
5. Uzak eşleşmesi olmayan tabletle: mesaj "Yeni eşleşme yalnız ev ağında…", yeniden deneme yok.
6. Yavaş hatta ilk keyframe 500 ms'de gelmezse STARTUP istekleri 0,5/1/2/4 sn aralıkla gider (host log).

## Open questions
