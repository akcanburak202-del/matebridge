---
id: T-134
title: Tablet — Mac'i saklanan IP'ye doğrudan TCP bağlanarak uyandır (magic packet işe yaramıyor)
status: done
phase: 4
owner: android-client-dev
depends_on: [T-133]
decisions: []
files:
  - client-android/app/src/
  - backlog/tasks/T-134-client-wake-by-direct-connect.md
---

## Amaç

Cihaz ölçümü (NOTES 2026-10-02 ~15:05–15:21): magic packet (174 paket, yayın + unicast :9) uyuyan Mac'i **uyandırmadı**. ICMP ping de uyandırmıyor (Wi-Fi çipi uykuda kendisi cevaplıyor). **Host'un dinleyen kontrol portuna (47001) TCP bağlantısı Mac'i 1 s içinde karanlık uyanmaya soktu ve bağlantı 435 ms'de kuruldu.** Karanlık uyanmada oturum kurulunca host (T-128 `session_started`) Mac'i tam uyandırıyor (14:44 testinde doğrulandı).

Mac uyurken Bonjour keşfi Mac'i bulamaz (uyku vekili yok), bu yüzden şu an uyandırma bölümünde tablet hiç TCP bağlantısı denemiyor.

## Kabul kriterleri

- [x] `WolStore` saklanan host IPv4'ün yanında kontrol **portunu** da saklar (TXT'nin geldiği çözümlemeden; yoksa 47001).
- [x] **Uyandırma bölümünde doğrudan bağlantı:** T-129 uyandırma bölümü başladığında (otomatik — ev ağında — ya da elle "Mac'i uyandır"/"Bağlan"), magic packet'lere ek olarak saklanan IP:port'a **normal oturum bağlantısı** (HELLO akışı, mevcut `SessionMachine` yolu) denenir: Wi-Fi ağına bağlı soketle, bağlantı zaman aşımı ~3 s, denemeler arası ~2 s, bölüm süresince (20 s). Bağlantı kurulursa normal oturum akışı (HELLO_ACK, şifreleme) devam eder ve bölüm `connected` ile biter. Keşif (NSD) paralel çalışmaya devam eder; hangisi önce bulursa o kullanılır, ikinci bağlantı açılmaz.
- [x] Bu doğrudan deneme yalnızca uyandırma bölümü içinde yapılır; "Mac uyku modunda" (BYE HOST_SLEEP) durumunda, kullanıcı eylemi/ön plana dönüş olmadan **hiç** paket gönderilmez (T-133 kuralı aynen).
- [x] Taşıma modu: Wi-Fi ve Otomatik modda (USB yoksa ya da USB kaybolduysa) çalışır. Otomatik modda Mac uyanıp USB tüneli geri gelirse mevcut auto/migrate mantığı USB'ye geçebilir (değişmez).
- [x] "Mac uyku modunda" durumunda "Bağlan" düğmesi de aynı yolu başlatır (uyandırma bölümü + doğrudan bağlantı); kullanıcının modu değiştirmesine gerek kalmaz.
- [x] Log: `MB/session ev=wake_connect attempt=N result=ok|timeout|refused|error ms=…` (adres yok). Bölüm başı/sonu T-129 logları aynen.
- [x] Saf mantık testli (bölüm içinde doğrudan deneme zamanlaması, keşifle yarış — tek bağlantı, host_sleep'te sessizlik). `./scripts/check.sh` geçiyor.

## Kapsam dışı

Host değişikliği yok. Cihaz testi (orkestratör).

## Plan

1. **`WolStore`:** `wol_port` anahtarı; `onResolved(host, port, txt, subnet)` portu host ile birlikte yazar; `port()` saklı yoksa 47001 (`ConnectMode.USB_CONTROL_PORT` = host kontrol portu). `MacDiscovery.onTxt` çözümlemenin portunu da verir (Wi-Fi keşfi ve T-133 USB TXT yenilemesi aynı yol).
2. **`SessionMachine`:** `Event.Start(endpoint, wakeAttempt = 0)`, `Action.OpenControl(gen, endpoint, wakeAttempt = 0)`. `wakeAttempt > 0` tek seferlik bir uyandırma denemesidir: TCP bağlanamazsa yeniden deneme zamanlayıcısı yok (faz `IDLE`, `Ui(Disconnected(CONNECT_FAILED, 0))`); `ControlOpened` gelince bayrak düşer ve oturum normal akışla sürer (HELLO_ACK, şifreleme, kopunca normal yeniden bağlanma).
3. **`SessionController`:** `start(endpoint, wakeAttempt)`; uyandırma denemesinin kontrol soketi `wifiBinder` ile Wi-Fi ağına bağlanır (`Network.bindSocket`; Wi-Fi yoksa bağlanmadan `result=error`), bağlantı zaman aşımı 3 s; sonuç `ev=wake_connect attempt=N result=ok|timeout|refused|error ms=…` (adres yok) ve `SessionListener.onWakeConnect(attempt, ok)`.
4. **Saf `session/WakeConnect.kt` (JVM testli):** bölüm içi doğrudan deneme zamanlaması: bölüm etkin + hedef var + oturum boşta (`canAttempt`: mod USB değil, USB'de değil, AUTO seçimi sürmüyor, mevcut uç nokta yok ya da bizim başarısız denememiz) → deneme N; sonuç gelmeden yeni deneme yok (kayıp sonuç için 3 s + pay sonra sıfırlanır); başarısızlıktan ~2 s sonra sonraki; `ok` ya da keşif bulursa bölümde başka deneme yok; yeni bölüm sayacı 1'den başlatır. `classify(IOException?)` → `ok|timeout|refused|error`. Keşif kararı: bizim denememiz sürerken/başarısızken keşif bulursa ona bağlanılır (SessionMachine `Start` önce eskisini kapatır → tek bağlantı); bölüm bitince başarısız denememiz serbest bırakılır (uç nokta temizlenir, "Mac aranıyor…").
5. **`MainActivity`:** `wolStep` sonunda `wakeConnectStep()`; `onWakeConnect` → planlayıcı (`ok` → uç nokta benimsenir, `lastWifiEndpoint`); `onDiscovered` keşif kuralı. "Mac uyku modunda"dayken "Bağlan" da `clear` + `applyTransport` + elle uyandırma bölümü (= "Mac'i uyandır"); ikisi de `currentEndpoint = null` yapar (yan bulgu: Wi-Fi modunda eski uç nokta keşfi engelliyordu). `hostSleep.asleep` iken bölüm yok → doğrudan deneme de yok (T-133 kuralı).
6. Testler: `WakeConnectTest`, `SessionMachineTest` (+wake deneme), `WolTest` (port).

## Handoff

- **Commit:** `f15abe3` (uygulama), plan `4061ad4`; dal `task/T-134-client-wake-connect` (4d4ad92'den). `./scripts/check.sh` → **ALL OK**. Yeni/değişen testler: `WakeConnectTest` 21, `SessionMachineTest` +5 (40), `WolTest` +1 (22).
- **Dosyalar:**
  - yeni `session/WakeConnect.kt` — saf planlayıcı (deneme zamanlaması, sahiplik, keşif kararı, `transportAllows`, `classify`/`errName`, `NoWifiException`); yeni `test/.../session/WakeConnectTest.kt`
  - `session/Wol.kt` — `WolStore`: `wol_port`, `port()` (yoksa 47001), `wakeEndpoint()`, `onResolved(..., hostPort)` (port yalnız geçerli IPv4 host + geçerli `wol` ile yazılır)
  - `session/MacDiscovery.kt` — `onTxt(host, wol, port)`
  - `session/SessionMachine.kt` — `Event.Start(endpoint, wakeAttempt)`, `Action.OpenControl(gen, endpoint, wakeAttempt)`; başarısız deneme → faz `IDLE`, `Ui(Disconnected(CONNECT_FAILED, 0))`, zamanlayıcı yok; `ControlOpened` sonrası normal oturum
  - `session/SessionController.kt` — `start(endpoint, wakeAttempt)`, `wifiBinder` yapıcı parametresi, `connectForWake()` (Wi-Fi'ye bağlı soket, 3 s, `ev=wake_connect`), `SessionListener.onWakeConnect`; `retryInMs=0` olan Disconnected `reconnect` yerine `ev=wake_connect_idle` loglanır
  - `session/SessionUi.kt` (yalnız yorum), `session/WolSender.kt` (`bindToWifi(Socket)`), `MainActivity.kt`
  - testler: `SessionMachineTest.kt`, `WolTest.kt`
- **Davranış / varsayımlar:**
  - Doğrudan deneme yalnızca `WakePlanner.active` iken (+ ön planda, "Bağlantıyı kes" yok, `hostSleep.asleep` değil). Bölüm hiç başlamazsa (saklı `wol` yok, otomatikte ev ağı dışı, uyku kapısı) deneme de yok. `wol` yoksa host IP de saklanmadığı için zaten hedef yok.
  - Deneme yalnızca oturum "boşta" iken: uç nokta seçilmemiş (Wi-Fi keşfi arıyor) ya da kendi başarısız denememiz; mod USB değil, oturum USB'de değil, AUTO yoklaması/düşüşü sürmüyor, elle adres yok. **AUTO'da `lastWifiEndpoint` biliniyorsa** (aynı etkinlikte önceden Wi-Fi'de bağlanıldıysa) `startWifi` ona hemen bağlanır; o oturumun kendi yeniden denemeleri de aynı IP:47001'e TCP olduğu için onlara dokunulmadı (doğrudan deneme araya girmez). Aynı şekilde kopmuş (LOST) bir oturumun yeniden denemeleri değişmedi.
  - Zamanlama: bölüm başında (elle: hemen; otomatik: T-129 2 s sonra) 1. deneme; sonuç gelmeden yeni deneme yok; başarısızlıktan 2 s sonra sonraki (hepsi zaman aşımına giderse ≈ 0, 5, 10, 15, 20 s). Sonuç 5 s içinde gelmezse (ör. başlatma posta kutusunda yenisiyle değişti) beklenmez. Deneme numarası her bölümde 1'den.
  - `result=ok` → oturum "benimsenir" (sıradan oturum, `lastWifiEndpoint`), bölümde başka deneme yok; bölüm host'a ulaşılınca `wol_stop reason=connected` ile biter. TCP açılıp ACK'ten önce kapanırsa normal yeniden bağlanma.
  - **Keşifle yarış:** keşif bizim denememiz sürerken ya da başarısızken bulursa ona bağlanılır (`Start` önce eski bağlantıyı kapatır → tek bağlantı; test `discoveryStartReplacesAWakeAttemptWithOneConnection`); sonra o bölümde doğrudan deneme yok. Benimsenmiş oturumda keşif kuralı eskisi gibi (yalnız Disconnected iken).
  - Bölüm doğrudan deneme başarısızken biterse (zaman aşımı) uç nokta bırakılır, panel "Mac aranıyor…" (keşif bağlanabilir). Uçuşta olan deneme bitene kadar (≤3 s) beklenir; geç başarı benimsenir.
  - `result`: `SocketTimeoutException` → `timeout`; `ConnectException` + `ECONNREFUSED`/"refused" → `refused`; diğer her şey `error` (+ `err=<SınıfAdı>` ya da Wi-Fi yoksa `err=no_wifi`; mesaj loglanmaz, adres içerir). Wi-Fi yoksa bağlanmadan `error`. Not: mevcut `session_start host=… port=…` ve `connect_start host=…` satırları (önceden de vardı) IP içerir; dokunmadım.
  - **"Mac uyku modunda" + "Bağlan"** artık "Mac'i uyandır" ile aynı: `clear` + uç nokta unutulur + `applyTransport` + elle bölüm (`wol_start reason=manual`). Elle adres alanı **açık ve dolu** ise o adrese bağlanır (yine elle bölüm başlar); gizli alanın hatırlanan metni sayılmaz.
  - **Yan bulgu düzeltmesi (NOTES 15:20):** uykudan sonra "Bağlan"/"Mac'i uyandır" `currentEndpoint`'i sıfırlamıyordu; Wi-Fi modunda keşif `currentEndpoint != null && lastUi == Searching` yüzünden bulduğu Mac'i yok sayıyordu (AUTO'da `lastWifiEndpoint` hemen bağlandığı için çalışıyordu). Artık `restartUsualWay()` önce sıfırlar.
  - Video bağlantısı (oturum benimsendikten sonra) Wi-Fi'ye bağlanmaz — tüm Wi-Fi oturumlarındaki gibi varsayılan ağ (tablette hücresel yok).
- **Codex incelemesi düzeltmesi (P2):** bölüm biterken uçuştaki denemenin gecikmiş "bağlandı" sonucu, sayacı 1'den başlayan yeni bölümün aynı numaralı denemesiyle eşleşip yeni bölümü `settled` yapabiliyordu. Artık her deneme `WakeTag(id, n)` taşır (`id` planlayıcı ömrü boyunca tekil, `n` bölüm içi numara; `SessionMachine` → `SessionController` → `onWakeConnect` boyunca aynı etiket) ve planlayıcı denemenin hangi bölümde başladığını tutar. Bitmiş bir bölümün sonucu yeni bölümü **yönlendirmez** (settle etmez, 2 s aralığı yüklemez); yalnız yuvayı boşaltır ve açtığı oturum hâlâ bizimse onu benimser. Testler: `lateSuccessFromAnEndedEpisodeDoesNotSettleTheNextOne`, `lateFailureFromAnEndedEpisodeDoesNotDelayTheNextOne`, `lateSuccessFromAnEndedEpisodeStillAdoptsItsLiveSession`, `tagsAreUniqueAcrossEpisodes`, `lostResultIsGivenUpAfterTheStaleTime` (geç sonuç yeni denemeye sayılmaz). `WakeConnectTest` 25, check.sh ALL OK.
- **Test edilmedi (tablet + Mac gerekli):** gerçek uyandırma, `Network.bindSocket` ile TCP, USB takılıyken Wi-Fi'den çıkış, sonuç sınıflandırmasının HarmonyOS istisna metinleri, panel metinleri.
- **Tablette kontrol edilecekler** (T-132 host'u ile, `adb logcat -s 'MB:*'`):
  1. Wi-Fi modunda bağlıyken `pmset sleepnow` → `host_sleep`; 1–2 dk hiç `wake_connect`/`wol_start`/`session_start` yok.
  2. Tablet ekranını kapat-aç (ev ağı) → ~2 s sonra `wol_start reason=not_found`, hemen ardından `session_start … wake_attempt=1` ve `wake_connect attempt=1 result=ok ms≈400–1000`; Mac `pmset -g log`'da DarkWake → tam uyanma; tablette oturum kurulur, `wol_stop reason=connected`.
  3. Aynı senaryoyu "Bağlan" ile (ekran açık, panel "Mac uyku modunda") → `host_sleep_clear reason=connect`, `wol_start reason=manual`, `wake_connect attempt=1 result=ok`; mod değiştirmeye gerek kalmamalı. "Mac'i uyandır" ile de aynı (`reason=wake`).
  4. Mac kapalı/ağ dışında iken elle uyandır → ~20 s boyunca `wake_connect attempt=1..5 result=timeout|error` (aralar ~2 s + 3 s zaman aşımı), sonra `wol_stop reason=timeout`, panel "Mac aranıyor…"; sonraki 30 s'de yeni deneme yok.
  5. AUTO modunda USB kablosu takılı (`adb reverse` var) iken Mac uyurken: USB yoklaması/düşüşü sonrası Wi-Fi'de `wake_connect … result=ok` (paket Wi-Fi'den çıkmalı); Mac uyanıp USB tüneli gelince mevcut `transport_pick`/`migrate` mantığı USB'ye geçebilir.

## Açık sorular

- AUTO'da `lastWifiEndpoint` biliniyorken oturumun kendi (bağlanmamış, 5 s zaman aşımlı) yeniden denemeleri Mac'i zaten TCP ile uyandırır ama Wi-Fi'ye bağlı soketle değildir; tablette varsayılan ağ Wi-Fi olduğu sürece fark yok. Gerekirse ayrı kart.
