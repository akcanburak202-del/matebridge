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

- **Commit:** `9d97235` (plan), `4e4cae2` (saf politika + `MacDiscovery.restart()` + testler + LOGGING), `ff8afa3` (MainActivity bağlantısı; kapsam orkestratör onayıyla genişletildi). Dal: `task/T-227-endpoint-rediscovery`.
- **Dokunulan dosyalar:**
  - `client-android/app/src/main/kotlin/dev/matebridge/client/session/EndpointRediscovery.kt` (yeni, saf politika)
  - `client-android/app/src/main/kotlin/dev/matebridge/client/session/MacDiscovery.kt` (`restart()`)
  - `client-android/app/src/test/kotlin/dev/matebridge/client/session/EndpointRediscoveryTest.kt` (21 test)
  - `client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt`:
    - `render()` → `rediscovery.onUi(...)`; `foreign`/`unreachable` olursa eski adrese dönüş `ui.post` ile yapılır, T-151 seçim işleminden sonra. Oturum o arada başka yere geçtiyse dokunulmaz.
    - `wolTicker` → `rediscoveryStep()` → `pairPick.clearSeen()` + `discovery?.restart()`.
    - `onDiscovered()` → `rediscovery.onDiscovered(...)`: `SKIP` olursa bağlanılmaz; `CONNECT` ya da var olan kural sağlanırsa `connect(ep, DISCOVERY)`. `wakeConnect.onDiscovered(...)` her durumda çağrılır.
    - Sıfırlama noktaları: `applyTransport()`, `startWifi()`, `userDisconnect()`, `onStop()`.
  - `docs/LOGGING.md` (`endpoint_rediscover`, `_found`, `_result`, `_skip`)
- **Varsayımlar:**
  - Kök neden: NSD bir hizmeti keşif başına bir kez bildiriyor; yalnızca adres değişince yeni `onServiceFound` gelmiyor. Düzeltme: kayıtlı adres art arda düşünce keşfi yeniden başlatmak. Yeni adres, eski adrese bağlanılırken bile hemen denenir.
  - Eşik: 2 düşüş ya da ilk düşüşten 4 sn sonra; sonra 8/16/30 sn aralık. Adres kaybolunca connect 5 sn asılı kalabildiği için zaman eşiği önemli. Beklenen toplam süre ≈ 4 sn + NSD çözümü + bağlantı, yani ≤ ~10 sn.
  - Kimlik = son doğrulanmış oturumun `HostTag`'i (host_id). Bu süreçte henüz kimlik görülmemişse ilk aday kabul edilir. Aşağıdakiler `foreign` sayılır; o adres bölüm boyunca atlanır ve eski adrese dönülür:
    - başka bir eşleşmiş Mac,
    - eşleşme isteyen bir Mac (`PairingNeedsUser`),
    - adayda kalıcı `Failed`.
  - Başka bir eşleşmiş Mac'te oturum, kimlik görülene kadar kısa süre `Connected` olabilir; ardından eski adrese dönülür.
  - "Kaydı güncelle": `connect()` `lastWifiEndpoint`'i günceller. Uyandırma adresi (`wolStore`) `onHostTxt` ile zaten güncelleniyor. Elle yazılmış adreste (`manualMode`), USB'de, "Bağlantıyı kes" sonrası ve HOST_SLEEP'te yeniden keşif kapalı.
  - Uyandırma yolu değişmedi: `WakeConnect` ve `wolStep` dokunulmadı. Yeniden keşif yalnızca yanına NSD yeniden başlatması ekliyor. Kayıtlı adres denemeleri (SessionMachine geri çekilmesi) sürüyor.
  - Uyandırma bölümü bitip oturum `Searching`e (uç nokta yok) düşerse yeniden keşif tetiklenmez (sayılacak uç nokta yok). Asıl senaryo, Disconnected yeniden deneme döngüsü, kapsanıyor.
- **Test edilmeyenler / cihazda doğrulananlar:** Cihazda hiçbir şey denenmedi (adb/tablet yok). `./scripts/check.sh` `ff8afa3` üzerinde geçti. Orkestratörün tablette denemesi gerekenler:
  1. Wi-Fi modunda bağlıyken Mac'te Ethernet'i tak ve Wi-Fi'yi kapat. Tablet uygulama yeniden açılmadan ≤ ~10 sn içinde yeniden bağlanmalı. `adb logcat -s 'MB:*'` içinde sırasıyla `ev=endpoint_rediscover reason=…`, `ev=endpoint_rediscover_found old=*.107 new=*.106`, `ev=endpoint_rediscover_result result=accepted` görülmeli.
  2. AUTO modunda (Wi-Fi'de) aynı deneme yapılmalı.
  3. Mac uykuya geçip uyandırılırken `wake_connect` satırları önceki gibi sürmeli; yeniden keşif yalnızca `endpoint_rediscover` satırları eklemeli.
  4. Mac kapalıyken geri çekilme sürmeli; `restart=` satırları 8/16/30 sn aralıkla gelmeli, yığılma olmamalı.
  5. Bağlıyken ve USB'deyken hiç `endpoint_rediscover` satırı çıkmamalı.
- **Açık sorular:**
  1. (Kapsam dışı, not) `onHostTxt` her çözümlemede `wolStore` uyandırma adresini kimlik denetimi olmadan güncelliyor (var olan davranış). Başka bir Mac'in çözümlemesi uyandırma hedefini değiştirebilir. T-227 bunu değiştirmiyor.
