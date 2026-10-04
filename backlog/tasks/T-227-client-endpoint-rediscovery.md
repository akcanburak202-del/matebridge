---
id: T-227
title: Client — when the stored Mac address stops answering, rediscover the host via Bonjour (Mac moved from Wi-Fi to Ethernet)
status: review
phase: 6
owner: android-client-dev
depends_on: []
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/
  - client-android/app/src/test/kotlin/dev/matebridge/client/session/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - docs/LOGGING.md
  - backlog/tasks/T-227-client-endpoint-rediscovery.md
---

## Amaç

Cihaz 2026-10-04 ~22:15 (T-127 topoloji 2): Mac Wi-Fi'den (192.168.1.107) Ethernet'e (192.168.1.106) geçince ve Mac Wi-Fi'si kapatılınca tablet Wi-Fi modunda Mac'i yeniden bulamadı; host Bonjour'da Ethernet arayüzünden (`dns-sd -B _matebridge._tcp` → if 7) görünüyordu. Kullanıcı uygulamayı kapatıp açınca hemen bağlandı. Yani açılıştaki keşif doğru adresi buluyor, ama çalışırken kayıtlı adrese yeniden bağlanma döngüsü yeni adresi aramıyor. Mac'in adresi değişince (Ethernet takma, DHCP yenileme, Mac yeniden başlama) uygulamayı yeniden açmak gerekmemeli.

## Bağlam

- Ajan önce mevcut akışı okur: kayıtlı uç nokta / `connect_start host=` / NSD keşfi / yeniden bağlanma ve geri çekilme (session paketi), T-096 otomatik taşıma, T-128..T-134 uyanma (kayıtlı IP'ye doğrudan TCP), `migrate_request`.
- İstenen davranış: Wi-Fi modunda kayıtlı adrese art arda N deneme (ör. 2–3, ya da ~5 sn) başarısız olursa NSD keşfini yeniden başlat; aynı `device`/host kimliğine ait yeni bir adres bulunursa ona bağlan ve kaydı güncelle. Eşleştirme kimliği (anahtar kanıtı) zaten bağlanınca doğrulanır; yeni adres kimliği değiştirmez. Bulunamazsa mevcut geri çekilme sürer.
- Uyku/uyanma yolu (kayıtlı IP'ye doğrudan TCP ile Mac'i uyandırma) bozulmamalı: uyuyan Mac Bonjour'da görünmeyebilir; yeniden keşif kayıtlı adres denemelerinin yerine değil, yanına gelir.
- Log: `ev=endpoint_rediscover reason=… old=<redacted?> new=…` — adresleri loglama kuralı için docs/LOGGING.md ve NOTES 2026-10-04 `migrate_request` IP notuna bakın; gerekirse adresin yalnız son okteti.

- **Kapsam (2026-10-04):** `MainActivity.kt` `files:` listesine orkestratör onayıyla eklendi (yeniden keşfin bağlantısı orada).

## Kabul kriterleri

- [ ] [JVM] Kayıtlı adres N kez başarısız → keşif başlar; keşif aynı host için yeni adres verince ona bağlanılır ve kayıt güncellenir.
- [ ] [JVM] Keşif sonuç vermezse kayıtlı adresle geri çekilme aynen sürer; uyandırma yolu değişmez.
- [ ] [JVM] Başka bir host (farklı kimlik) yeni adres olarak kabul edilmez.
- [ ] [device] Mac Wi-Fi → Ethernet geçişinde (Mac Wi-Fi kapatılarak) tablet uygulama yeniden açılmadan ≤ ~10 sn içinde yeniden bağlanır.

## Plan

Mevcut akış (okundu): `MainActivity.startWifi()` bir `MacDiscovery` başlatır; NSD bir hizmeti **bir kez** bildirir. `onDiscovered()` → `wakeConnect.onDiscovered(current, disconnected=lastUi is Disconnected, …)` zaten "oturum Disconnected iken bulunan her uç noktaya bağlan" diyor. Kopan oturumu `SessionMachine` aynı adrese 1→5 sn geri çekilmeyle (connect zaman aşımı 5 sn) yeniden dener. Sorun: Mac'in adresi değişince (Wi-Fi → Ethernet, aynı hizmet adı) NSD yeni bir `onServiceFound` vermiyor, bu yüzden `onDiscovered` hiç çağrılmıyor. Uygulama yeniden açılınca yeni keşif doğru adresi buluyor.

1. **`EndpointRediscovery` (session/, saf, saat enjekte, ana thread)**:
   - `onUi(state, current, nowMs)`: o anki uç noktanın art arda düşüşlerini sayar (`Disconnected(retryInMs>0)`'a her geçiş bir başarısızlıktır, ilk düşüş anı da tutulur). `Connected` başarısızlık sayacını sıfırlar ve host kimliğini (`HostTag`, kimliği doğrulanmış oturum) öğrenir. Uç nokta değişince ya da başka bir durum gelince (Failed, eşleşme istemi, Idle/Searching) sayaç sıfırlanır.
   - `shouldRestart(nowMs, eligible)`: `eligible` (Wi-Fi keşif modu, manuel adres değil, USB değil, kullanıcı kesmedi, Mac uyku demedi) ve (≥ 2 başarısızlık **ya da** ilk düşüşten bu yana ≥ 4 sn) ise NSD keşfini yeniden başlat der; sonraki yeniden başlatmalar 8 → 16 → 30 sn aralıkla (üst sınır) sürer. Kayıtlı adres denemeleri ve uyandırma yolu değişmez: yeniden keşif onların **yanına** gelir.
   - `onDiscovered(ep, current, ui)`: yeniden keşif etkinken, eski adresten farklı ve "yabancı" işaretli olmayan bir uç nokta bulunursa, oturum Disconnected **ya da Connecting(eski adres)** durumundaysa ona bağlanılmasını söyler (NSD sonucu bir kez geldiği için Connecting sırasında kaybolmasın). Adayı ve eski adresi hatırlar.
   - Kimlik: aday `Connected(hostTag)` olunca öğrenilen kimlikle karşılaştırılır. Aynıysa (ya da önceden kimlik yoksa) `Accepted(old,new)`: kayıt güncellenir. Farklı kimlik (başka eşleşmiş Mac) ya da `PairingNeedsUser` (eşleşmemiş Mac) → `Foreign`: o adres bu bölüm için yabancı işaretlenir ve çağıran eski adrese geri bağlanır (geri çekilme sürer).
2. **`MacDiscovery.restart()`**: dinleyiciyi durdurup aynı nesneyle yeni nesil keşif başlatır (NSD hizmeti yeniden bildirir).
3. **Log** (`docs/LOGGING.md`): `ev=endpoint_rediscover reason=connect_failed restart=N`, `ev=endpoint_rediscover_found old=*.107 new=*.106`, `ev=endpoint_rediscover_result result=accepted|foreign`; adreslerin yalnız son okteti (`EndpointRediscovery.octet()`).
4. **JVM testleri** (`EndpointRediscoveryTest`): N başarısızlık → yeniden başlatma; zaman eşiği; aralık/üst sınır; yeni adres → bağlan + Accepted; sonuç yok → yalnızca yeniden başlatma, eski adres denemeleri etkilenmez; farklı kimlik/PairingNeedsUser → Foreign ve yabancı adres yeniden kabul edilmez; Connected/istem sırasında bağlanma yok; uygun değilken (USB, manuel) yeniden başlatma yok.
5. **MainActivity bağlantısı (kart `files:` dışında — Açık sorular)**: `render()` → `rediscovery.onUi(...)` ve sonucuna göre log/eski adrese dönüş; `wolTicker` → `shouldRestart(...)` → `pairPick.clearSeen(); discovery?.restart()`; `onDiscovered()` → `rediscovery.onDiscovered(...)` ile `wakeConnect.onDiscovered(...)` VEYA'lanır; `applyTransport()/onStop()/disconnect` → `rediscovery.reset()`.

## Handoff

- **Commit:**
  - `9d97235` plan.
  - `4e4cae2` saf politika, `MacDiscovery.restart()`, testler, LOGGING.
  - `ff8afa3` MainActivity bağlantısı.
  - `35cb0cd` Codex inceleme düzeltmeleri (3 × P1).
  - `f22f8a2` Codex ikinci tur düzeltmeleri (P1 + P2).
  - `aee92a4` Codex üçüncü tur düzeltmeleri (2 × P2).
  - Dal: `task/T-227-endpoint-rediscovery`.
- **Dokunulan dosyalar:**
  - `client-android/app/src/main/kotlin/dev/matebridge/client/session/EndpointRediscovery.kt` (yeni, saf politika)
  - `client-android/app/src/main/kotlin/dev/matebridge/client/session/MacDiscovery.kt` (`restart()`)
  - `client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionMachine.kt`:
    - `Event.Start.expectHost`,
    - `Event.ExpectHost(endpoint, host)` (çalışan yeniden denemeyi kapıya bağlar),
    - kimlik kapısı `wrongHost()` / `refuseWrongHost()`.
  - `client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionController.kt`:
    - `start(..., expectHost)`,
    - `expectHost(endpoint, host)` (kendi `Latest` posta kutusu),
    - log: `expect_host`, `session_start expect_host=1`.
  - `client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionUi.kt`: `Cause.WRONG_HOST`, `Failed.endpoint` (makine her `Failed`'a biten başlangıcın adresini koyar; eşitliğe girmez, mevcut testler etkilenmez).
  - `client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt` (orkestratör onayıyla):
    - `render()` → `rediscovery.onUi(...)` + eski adrese dönüş (`ui.post`),
    - `wolTicker` → `rediscoveryStep()`; her yeniden başlatmada çalışan oturum `controller.expectHost(...)` ile kapıya bağlanır (uyandırma denemesi değilse),
    - `onDiscovered()`: `SKIP` kontrolü artık `pairPick.onDiscovered`'dan önce,
    - `connect()`: otomatik başlangıçlara bölüm sırasında `expectHost`,
    - `tryNextAfterPick()` yabancı adresi atlar,
    - `causeText(WRONG_HOST)`,
    - sıfırlama: `applyTransport/startWifi/userDisconnect/onStop`.
  - Testler:
    - `EndpointRediscoveryTest.kt` (31),
    - `WrongHostGateTest.kt` (10, yeni).
  - `docs/LOGGING.md`: `endpoint_rediscover`, `_found`, `_result`, `_skip`, `wrong_host`, `expect_host`.
- **İnceleme düzeltmeleri (Codex 3 × P1):**
  1. **Pano sızıntısı.** Kimlik denetimi bağlantıdan önceye alınamadı: TXT kaydında host_id yok, yalnız `v` ve `wol` var. Onu eklemek protokol değişikliği olur. Bunun yerine kimlik kapısı oturum makinesine kondu. Bölüm sırasındaki her otomatik başlangıç `expectHost` = son doğrulanmış host'un `HostTag`'ini taşır. Makine ilk yanıtta (`Secured`, `PairingNeedsUser`, `PairedWithPending`) farklı host_id görürse ya da başka bir Mac eşleşme isterse bağlantıyı HELLO_ACK'tan önce kapatır ve `Failed(WRONG_HOST)` verir. Böylece `Connected` hiç gelmez; pano, dosya ve girdi açılmaz. Beklenen host_id'yi taklit eden biri de anahtarımızı bilmediği için mühürlü kayıtları okuyamaz; T-156 anahtar uyuşmazlığı onu yakalar ve aday `foreign` olur. Bu, kayıtlı adrese bugün yapılan sıradan yeniden bağlanmayla aynı tehdit modeli.
  2. **Eski oturumun geç durumu.** Aday seçildikten sonra, adayın `Connecting`'i görülene kadar gelen her durum eski oturumun geç durumu sayılır ve hiçbir şeye karar vermez: bölümü bitirmez, kimlik öğrenmez. Tek istisna `StoredTrust`/`Failed`: adayın başlangıcı bağlanmadan bunlarla bitebilir, o zaman yalnızca aday izlemesi bırakılır. Asıl güvence yine makinedeki kapı: `expectHost` başlangıç olayına bağlı, UI iş parçacığı yarışından etkilenmez.
  3. **Seçim geri dönüşü.** `SKIP` adresler artık `pairPick`'e hiç verilmiyor. `tryNextAfterPick()` yabancı adresi atlıyor. Bu yoldan gelen bağlantı da `connect()` üzerinden kapıdan geçiyor.
- **İkinci tur düzeltmeleri (Codex P1 + P2):**
  1. **P1 — eski adresi zaten deneyen oturum kapısızdı.** Bölüm başladığında (her yeniden başlatmada, tekrarı zararsız) MainActivity `controller.expectHost(currentEndpoint, sonDoğrulanmışHost)` gönderir. Makine `Event.ExpectHost`'u yalnız şu koşulda uygular: oturum o adreste çalışıyor, IDLE değil, ve kabul edilmemiş bir kullanıcı başlangıcı değil. Kabulden sonra yeniden denemeler zaten otomatik. Uygulanınca sonraki her yeniden denemede başka bir host_id HELLO_ACK'tan önce `WRONG_HOST` ile reddedilir. İlk yanıtı başka bir host'tan almış bir bağlantı varsa o da hemen kapatılır. Uyandırma denemesi (`wakeConnect.owned`) bağlanmaz.
  2. **P2 — geç gelen ret yeni adrese yükleniyordu.** `Failed(WRONG_HOST)` artık reddedilen başlangıcın adresini taşıyor. Adres oturumun şimdiki adresi değilse, durum eski bir başlangıcın geç sonucu sayılır ve hiçbir şeye karar vermez: kara listeye almaz, geri dönmez, aday izlemesini bozmaz.
  3. **Önceki açığın kapanması.** Eski adresin kendisinde ret gelirse bölüm durmaz. Akış, o adres düşmeye devam ediyormuş gibi sürer: keşif aralıkla yeniden başlar ve host'umuzun yeni adresi `Failed(WRONG_HOST)` durumundan da hemen denenir.
- **Üçüncü tur düzeltmeleri (Codex 2 × P2):**
  1. **Eski bağlantının geç gelen kalıcı durumu aday izlemesini düşürüyordu.** Artık her `Failed` başlangıcının adresini taşıyor. Adres oturumun şimdiki adresi değilse durum yok sayılır. Adayın kendi başlangıcı bağlanmadan bitse bile (ör. kilit) aday yine değerlendirilir ve `foreign` sonucu verir.
  2. **Kullanıcı başlangıcı bölümü bitirmiyordu.** `connect()` içinde otomatik olmayan her başlangıç `rediscovery.onUserStart()` çağırıyor; bu bölümü kapatır. Kullanıcının seçtiği Mac `foreign` sayılmaz ve uygulama eski adrese geri atlamaz. Kuyruktaki bir geri dönüş de çalışmadan önce bölümün hâlâ etkin olduğunu denetliyor.
- **Varsayımlar:**
  - Kök neden: NSD bir hizmeti keşif başına bir kez bildiriyor, bu yüzden düzeltme keşfi yeniden başlatmak.
  - Eşik: 2 düşüş ya da 4 sn; sonraki yeniden başlatmalar 8/16/30 sn aralıkla.
  - Kapı yalnızca etkin bir bölüm sırasında ve bu süreçte en az bir doğrulanmış oturum görülmüşse açık. Bölüm dışındaki keşif davranışı değişmedi.
  - Kendi host'umuz yeni adreste yeniden eşleşme isterse (aynı host_id) olağan T-151 istemi gelir.
  - Eski adreste `WRONG_HOST` çıkarsa o adres bölüm boyunca atlanır. Yeni adres bulunana kadar ekranda bağlantı hatası metni kalır.
  - Uyandırma yolu (`WakeConnect`, `wolStep`) değişmedi; uyandırma denemeleri kapısız.
- **Test edilmeyenler / cihazda doğrulananlar:** Cihazda hiçbir şey denenmedi. `./scripts/check.sh` `aee92a4` üzerinde geçti. Tablette denenecekler:
  1. Wi-Fi modunda bağlıyken Mac'te Ethernet'i tak ve Wi-Fi'yi kapat. Tablet uygulama yeniden açılmadan ≤ ~10 sn içinde yeniden bağlanmalı. Log sırası: `endpoint_rediscover reason=…`, `endpoint_rediscover_found old=*.107 new=*.106`, `endpoint_rediscover_result result=accepted`. `expect_host` satırı görülebilir; `wrong_host` çıkmamalı.
  2. Aynı deneme AUTO modunda (Wi-Fi'de) yapılmalı.
  3. Mac uyurken uyandırma: `wake_connect` satırları önceki gibi sürmeli.
  4. Mac kapalıyken `restart=` satırları 8/16/30 sn aralıkla gelmeli.
  5. Bağlıyken ya da USB'deyken hiç `endpoint_rediscover` satırı çıkmamalı.
- **Açık sorular:**
  1. (Kapsam dışı, not) `onHostTxt` her çözümlemede `wolStore` uyandırma adresini kimlik denetimi olmadan güncelliyor (var olan davranış). T-227 bunu değiştirmiyor.
  2. (Orkestratöre) Bağlanmadan önce kimlik denetimi istenirse, host TXT kaydına host_id eklemek protokol değişikliği gerektirir (PROTOCOL.md 3.1, iki taraf). Makinedeki kapı bunu gerektirmiyor.
