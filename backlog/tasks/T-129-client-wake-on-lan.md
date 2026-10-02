---
id: T-129
title: Tablet — Mac bulunamayınca Wake-on-LAN magic packet ile uyandır (TXT `wol`)
status: review
phase: 4
owner: android-client-dev
depends_on: []
decisions: []
files:
  - client-android/app/src/
  - backlog/tasks/T-129-client-wake-on-lan.md
---

## Amaç

Kullanıcı kararı (2026-10-02): Mac uzun süre kullanılmayınca uyusun; kullanıcı tableti açınca Mac tabletten uyandırılsın. Mac mini Wi-Fi'de, `Wake On Wireless: Supported`, `womp 1`. Host Bonjour TXT'de `wol=` ile MAC adreslerini yayınlar (T-128; format `docs/PROTOCOL.md` §3 madde 1).

## Kabul kriterleri

- [ ] `MacDiscovery` çözümlenen hizmetin TXT `wol` değerini ayrıştırır (PROTOCOL.md formatı; geçersiz adresler atlanır, en çok 4) ve son görülen host IPv4 adresiyle birlikte kalıcı saklar (SharedPreferences; MAC'ler loglanmaz). TXT'de `wol` yoksa önceki saklanan değer silinmez (eski host / geçici durum), yeni değer gelince değiştirilir.
- [ ] **Ne zaman uyandırılır:** uygulama ön plandayken ve bağlı değilken (ilk açılış, ekran açılınca yeniden bağlanma, bağlantı kopması) saklanmış `wol` varsa ve Mac kısa sürede (ör. ~2 s, sabit) bulunamıyor / bağlantı kurulamıyorsa, uyandırma bölümü başlar: magic packet her 1 s'de bir, en çok ~20 s (sabitler), bağlantı kurulunca hemen durur. Bölüm bitip hâlâ bağlantı yoksa mevcut yeniden bağlanma mantığı sürer; yeni bölüm en erken 30 s sonra ya da kullanıcı elle isteyince. Arka planda hiç gönderilmez.
- [ ] **Paket:** 6 × `0xFF` + 16 × MAC (102 bayt), UDP port 9; hedefler: `255.255.255.255`, Wi-Fi ağının alt ağ yayın adresi (LinkProperties'ten) ve son görülen host IPv4 (unicast). Soket Wi-Fi ağına bağlanır (`Network.bindSocket`; USB/adb tünel varken de Wi-Fi'den gitmeli), `broadcast = true`. Wi-Fi yoksa sessizce atlanır (log). Her MAC için ayrı paket.
- [ ] **UI:** uyandırma bölümünde panelde "Mac uyandırılıyor…" durumu; panelde elle "Mac'i uyandır" düğmesi (saklanmış `wol` yoksa gizli ya da devre dışı). Metinler Türkçe, mevcut panel üslubunda.
- [ ] Log: `MB/session ev=wol_start reason=… macs=N targets=M`, `ev=wol_stop reason=connected|timeout|background sent=K`, gönderim hatası `ev=wol_send_failed` (oran sınırlı). MAC/IP adresleri loglanmaz.
- [x] Saf mantık testli (JVM unit test): magic packet baytları, TXT `wol` ayrıştırma (geçerli/geçersiz/fazla adres), uyandırma bölümü zamanlayıcısı (başla, 1 s aralık, 20 s sınır, bağlanınca dur, 30 s bekleme, elle tetikleme).
- [x] Mevcut bağlanma / keşif davranışı uyandırma olmadan değişmez; girdi bırakma (release-all) kurallarına dokunulmaz.
- [x] `./scripts/check.sh` geçiyor.

## Kapsam dışı

- Cihaz testi, APK kurulumu (orkestratör yapar). Protokol değişikliği yok (TXT anahtarı PROTOCOL.md'de tanımlı).

## Plan

1. **Saf mantık** `session/Wol.kt` (JVM testli):
   - `WolTxt`: TXT `wol` ayrıştırma (virgülle böl, boşluk kırp, `aa:bb:cc:dd:ee:ff` hex — büyük harf de kabul, küçük harfe normalize; geçersiz / sıfır / multicast adresler atlanır, tekrarlar atlanır, en çok 4). Değer var ama geçerli adres yoksa "yeni değer yok" sayılır (saklanan korunur).
   - `WolPacket`: 6 × `0xFF` + 16 × MAC = 102 bayt, port 9.
   - `WolTargets`: IPv4 literal ayrıştırma, alt ağ yayın adresi (`addr | ~mask`, önek 0..30; /31 ve /32 için yok), hedef listesi (255.255.255.255 + alt ağ yayınları + son host unicast, tekrarsız).
   - `WolStore(KeyValueStore)`: `wol_macs` + `wol_host` anahtarları; bellekte önbellek, `@Synchronized`; `onResolved(host, txt)` host'u her zaman, MAC'leri yalnızca geçerli yeni değer gelince yazar; değişince true döner.
   - `WakePlanner`: saat dışarıdan; `update(now, foreground, userOff, reached, hasWol)` ve `manual(now, reached, hasWol)` → `Start(reason) / Send / Stop(reason)` adımları. Sabitler: GRACE 2 s, INTERVAL 1 s, EPISODE 20 s, COOLDOWN 30 s. Bağlanınca (Connected / AwaitingApproval / Failed = host cevap verdi) hemen `Stop(connected)` ve bekleme sıfırlanır; arka plan `Stop(background)`; kullanıcı "Bağlantıyı kes" `Stop(user)`; zaman aşımı `Stop(timeout)` + 30 s bekleme; ön plana dönüş beklemeyi sıfırlar; elle tetikleme beklemeyi yok sayar, çalışan bölümü uzatır.
2. **Android ince sarmalayıcı** `session/WolSender.kt`: tek iş parçacıklı sınırlı kuyruklu executor (`mb-wol`). Bölüm başında Wi-Fi `Network` (ConnectivityManager, TRANSPORT_WIFI) + `LinkProperties` → hedefler; `DatagramSocket` `Network.bindSocket` ile Wi-Fi'ye bağlı, `broadcast = true`; her MAC × her hedef için ayrı paket. Wi-Fi yoksa `ev=wol_no_wifi` (bölüm başına bir kez) ve atlanır. Loglar: `wol_start reason= macs= targets=`, `wol_stop reason= sent=`, `wol_send_failed` (5 s'de en çok bir, `suppressed=` sayacıyla). MAC/IP loglanmaz.
3. **`MacDiscovery`**: isteğe bağlı `onTxt(host, wol)` geri çağrısı; çözümlenen hizmetin TXT `wol` değeri `WolStore`'a yazılır (`ev=wol_stored macs=N` yalnızca değişimde).
4. **`MainActivity`**: `WolStore` + `WakePlanner` + `WolSender`; 250 ms'lik `wolTicker` (yalnızca started iken) ve `render()` içinde anında adım; `onStop`'ta `Stop(background)`; `userDisconnect`'te `Stop(user)`. Durum metni: bölüm etkinken ve host'a ulaşılmamışken "Mac uyandırılıyor…". Bağlantı panelinde "Mac'i uyandır" düğmesi (saklanmış `wol` yoksa GONE); "Bağlantıyı kes" sonrası basılırsa önce Bağlan gibi taşıma yeniden uygulanır.
5. Layout'a düğme, `strings.xml`'e iki metin. Testler: `WolTest.kt`, `WakePlannerTest.kt`.

## Handoff

- **Commit:** `b8c40af` (uygulama), `904f43c` (inceleme düzeltmeleri), plan `847cad5`; dal `task/T-129-client-wol`. `./scripts/check.sh` → ALL OK (yeni: `WolTest` 21, `WakePlannerTest` 20 test).
- **Dosyalar:**
  - yeni `client-android/app/src/main/kotlin/dev/matebridge/client/session/Wol.kt` — saf: `WolTxt`, `WolPacket`, `WolTargets`, `Ipv4Subnet`, `HomeNetwork`, `WolStore`, `WakePlanner`
  - yeni `client-android/app/src/main/kotlin/dev/matebridge/client/session/WolSender.kt` — ince Android sarmalayıcı (`mb-wol` iş parçacığı, kuyruk 16; `wifiSubnets()`)
  - `session/MacDiscovery.kt` — isteğe bağlı `onTxt(host, wol)` (TXT `wol`, US-ASCII; try/catch içinde, hata `onFound`/çözümlemeyi durdurmaz)
  - `MainActivity.kt` — planner/sender/store bağlantısı, 250 ms `wolTicker`, `render()` içinde anında adım, durum metni, düğme
  - `res/layout/activity_main.xml` (`@+id/wake`, varsayılan GONE), `res/values/strings.xml` (`wol_button`, `wol_waking`)
  - testler: `app/src/test/.../session/WolTest.kt`, `WakePlannerTest.kt`
- **Varsayımlar / kararlar:**
  - "Host'a ulaşıldı" (Mac uyanık) = `Connected`, `AwaitingApproval`, `Failed` (REJECTED, VERSION_MISMATCH, KEY_*) ya da host cevabıyla biten `Disconnected` (BUSY, HOST_CLOSED, PROTOCOL_ERROR — SessionMachine bunları `lose()` ile yeniden denenecek `Disconnected` olarak verir, `Failed` değil). `Disconnected(CONNECT_FAILED | LOST)`, `Searching`, `Connecting`, `Idle` ulaşılmamış sayılır (LOST, uykuya giden Mac'in görünüşü). Bölüm 2 s ulaşılmamışlıktan sonra başlar.
  - TXT'de `wol` var ama geçerli adres yoksa "yeni değer yok" sayılır, saklanan korunur. Büyük harfli hex kabul edilir (küçüğe normalize); sıfır/multicast/yayın MAC'leri ve tekrarlar atlanır.
  - Host IPv4 ve tabletin o andaki Wi-Fi alt ağı (ağ adresi + önek; host'u içeren alt ağ, yoksa ilki) yalnızca TXT'de geçerli `wol` geldiğinde MAC'lerle birlikte saklanır (`wol_host`, `wol_subnet`); IPv6/ad saklanmaz. `wol` yoksa hiçbir şey değişmez.
  - **Otomatik uyandırma yalnızca ev ağında** (inceleme kararı): bölüm zamanı gelince güncel Wi-Fi alt ağları saklanan alt ağı içermiyorsa başlamaz; `ev=wol_skip reason=other_network|no_wifi|home_unknown` (aynı neden bir kez loglanır, adres yok), denetim 5 s'de bir tekrarlanır. Saklı alt ağ yoksa (`home_unknown`) otomatik bölüm yok. Elle "Mac'i uyandır" kısıtsız.
  - Bekleme (30 s) yalnızca zaman aşımından sonra; host'a ulaşılınca ya da uygulama ön plana dönünce sıfırlanır (ekranı açmak yeni başlangıç sayılır, yine 2 s bekler). Arka plana geçiş beklemeyi başlatmaz.
  - Ek durdurma nedeni `reason=user` ("Bağlantıyı kes"; kartta yoktu). Kesildikten sonra otomatik uyandırma yok; "Mac'i uyandır"a basmak Bağlan gibi taşımayı yeniden uygular ve bölümü başlatır. Çalışan bölümde elle basmak 20 s'yi yeniden başlatır ve hemen gönderir (`ev=wol_manual active=1`).
  - Durdurma kaybolmaz: `stop()` çalışan bölümü çağıran iş parçacığında hemen sıfırlar (kuyruktaki gönderim her datagramdan önce denetler), kuyrukta en çok bir gönderim bekler, kuyruk dolu/kapalıysa durdurma (soket kapatma + `wol_stop … inline=1`) yerinde çalışır.
  - `sent=K` başarılı gönderilen datagram sayısıdır (MAC × hedef × tur). Bir hedef hata verirse diğerleri yine gönderilir; turda hiçbiri gitmezse soket kapatılır ve sonraki turda Wi-Fi yeniden çözülür. `wol_send_failed` 5 s'de en çok bir kez (`suppressed=`), Wi-Fi yoksa `wol_no_wifi` bölüm başına bir kez.
  - Wi-Fi ağı `ConnectivityManager.allNetworks` içinde `TRANSPORT_WIFI` olan ilk ağdır (deprecated API; bölüm başında, çözümlemede ve ev ağı denetiminde en çok 5 s'de bir arama). Hedefler: 255.255.255.255, LinkProperties'teki her IPv4 için alt ağ yayını (/31, /32 hariç), son host IPv4.
  - Saklanan `wol` yalnızca Wi-Fi keşfi (NSD) çalıştığında güncellenir; yalnız USB modunda hiç Wi-Fi keşfi olmadıysa düğme görünmez.
  - Var olan `discovery_resolved host=… ` logu (önceden de vardı) IP içeriyor; dokunmadım. Yeni loglarda MAC/IP yok.
- **Test edilmedi (tablet gerekli):** gerçek NSD TXT okuma (HarmonyOS `NsdServiceInfo.attributes`), `Network.bindSocket` + broadcast gönderimi, Mac'in gerçekten uyanması, düğme / durum metni görünümü.
- **Tablette kontrol edilecekler:**
  1. Mac uyanıkken (T-128 host'u ile) uygulamayı aç → `adb logcat -s 'MB:*'` içinde bir kez `ev=wol_stored macs=N home=1` (N ≥ 1), bağlantı panelinde "Mac'i uyandır" düğmesi görünür; bağlıyken hiç `wol_start` yok.
  2. `pmset sleepnow` ile Mac'i uyut, tablette uygulamayı aç (ya da ekranı aç) → ~2 s sonra `ev=wol_start reason=not_found macs=N targets=M` (M genelde 3), panelde "Mac uyandırılıyor…"; Mac uyanıp bağlanınca `ev=wol_stop reason=connected sent=K` (K > 0).
  3. Mac uyanmazsa ~20 s'de `wol_stop reason=timeout`, sonraki `wol_start` en erken 30 s sonra; "Mac'i uyandır"a basınca hemen `wol_start reason=manual`.
  4. Bölüm sürerken tableti kilitle → `wol_stop reason=background`, ekran kapalıyken hiç `wol_start` yok.
  5. Mac uyanıkken başka bir istemci bağlıyken (BUSY) tablette `wol_start` olmamalı, "Mac meşgul" metni görünmeli.
  6. Başka bir Wi-Fi ağında (ör. telefon hotspot'u) uygulamayı aç → `wol_skip reason=other_network`, `wol_start` yok; "Mac'i uyandır" yine `wol_start reason=manual` verir.
  7. USB kablosu takılı ve `adb reverse` kuruluyken Mac'i uyut: bölüm yine başlamalı ve Mac uyanmalı (paket Wi-Fi'den gider). Gerekirse aynı ağdaki başka bir makinede `tcpdump udp port 9` ile paketleri gör.
