---
id: T-129
title: Tablet — Mac bulunamayınca Wake-on-LAN magic packet ile uyandır (TXT `wol`)
status: in_progress
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
- [ ] Saf mantık testli (JVM unit test): magic packet baytları, TXT `wol` ayrıştırma (geçerli/geçersiz/fazla adres), uyandırma bölümü zamanlayıcısı (başla, 1 s aralık, 20 s sınır, bağlanınca dur, 30 s bekleme, elle tetikleme).
- [ ] Mevcut bağlanma / keşif davranışı uyandırma olmadan değişmez; girdi bırakma (release-all) kurallarına dokunulmaz.
- [ ] `./scripts/check.sh` geçiyor.

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

(ajan doldurur)
