---
id: T-090
title: Tablet — ham ağ hızı ölçüm kipi (`--es net_bench host:port`), Wi-Fi kapasitesini uygulamadan bağımsız ölçmek için
status: review
phase: 5
owner: android-client-dev
depends_on: [T-089]
decisions: []
files:
  - client-android/app/src/main/
  - client-android/app/src/test/
  - backlog/tasks/T-090-client-net-bench.md
---

## Amaç

Wi-Fi ölçümü (orkestratör, 2026-10-01 ~17:45):
- Akıcı modda Wi-Fi akışı ~27 Mbps'te doyuyor: 8–11 fps, gecikme 350–390 ms, host gönderim kuyruğu 300 KB–1,1 MB, RTT yük altında ~28 ms (boşta 5–22 ms).
- `wifi_ll`, `tos` ve `SERVICE_CLASS` fark yaratmadı.
- Tablette `nc`, `curl` ve `wget` yok; ham TCP kapasitesi ölçülemiyor.

Mac tarafında basit bir Python gönderici/alıcı çalışacak (orkestratör scratch). Tablet tarafına bir deney kipi gerekiyor.

## Kabul kriterleri

- [ ] `am start -n dev.matebridge.client/.MainActivity --es net_bench HOST:PORT [--ei net_bench_s 8] [--es net_bench_dir down|up|both] [--ei net_bench_streams 1]`:
  - Normal oturum **başlatılmaz**.
  - Arka plan iş parçacığında HOST:PORT'a TCP bağlanır.
  - `down`: gelen baytları süre boyunca okuyup atar. `up`: 64 KB tamponları süre boyunca yazar. `both`: iki ayrı bağlantı açar.
  - `net_bench_streams` N paralel bağlantı açar (1–4).
  - Her saniye log yazar: `MB/netbench ev=tick dir=… mbps=… bytes=…`. Sonunda özet: `ev=done dir=… mbps_avg=… mbps_min=… mbps_max=…`.
  - Okuma tamponu 256 KB. `SO_RCVBUF` ayarlanmaz (varsayılan otomatik ayar korunur); isteğe bağlı `--ei net_bench_rcvbuf_kb N`.
- [x] Ekranda basit bir metin: "Ağ ölçümü… X Mbps". Bitince kendiliğinden kapanmaz, sonuç ekranda kalır.
- [x] Kip yalnızca bu ek parametreyle çalışır. Normal açılış davranışı değişmez. Kimlik doğrulama ya da şifreleme yoktur (ham soket; yalnızca deney). Uygulama bu kipte hiçbir girdi göndermez.
- [x] Saf mantık (parametre ayrıştırma, Mbps hesabı) testli.
- [x] `./scripts/check.sh` geçiyor.

## Plan

1. **Saf mantık (`bench/NetBench.kt`, yeni, Android'siz):** `NetBenchConfig.parse(getString, has, getInt)`. Kurallar: `net_bench` için `Endpoint.parse`, geçersizse null. `net_bench_s` varsayılan 8, [1, 600] aralığına sıkıştırılır. `net_bench_dir` down|up|both, varsayılan down; bilinmeyen değer down sayılır. `net_bench_streams` [1, 4]. `net_bench_rcvbuf_kb` yalnız >0 ise uygulanır. `Throughput.mbps(bytes, nanos)`. `ThroughputStats` saniyelik örnekleri toplar ve ort/min/max ile log alanlarını verir.
2. **Çalıştırıcı (`bench/NetBenchRunner.kt`, yalnız java.net):** Her yön için N soket açar (`connect` zaman aşımı 3 s, `rcvbuf` istenirse `connect` öncesinde). Her bağlantıda tek satırlık ASCII başlık yazar: `netbench dir=down|up stream=i secs=S\n`. Mac betiği bununla bağlantıları ayırabilir; okumazsa zararı yoktur. İş parçacıkları: down için 256 KB tamponla okuyup atar, up için 64 KB tampon yazar. Ortak `AtomicLong` sayaçları vardır. Koordinatör her saniye `ev=tick`, sonunda `ev=done` yazar, soketleri kapatır ve `cancel()` destekler. Logger ve UI geri çağrısı lambda olarak verilir.
3. **`NetBenchActivity` (yeni, dışa açık değil, manifest'te yatay):** Programatik `TextView` kullanır ("Ağ ölçümü… X Mbps"), ekran açık kalır, sonuç ekranda durur. `onDestroy` içinde `cancel` çağrılır.
4. **MainActivity:** `super.onCreate` sonrası `net_bench` eki varsa ekleri `NetBenchActivity`'ye iletir, `finish()` eder ve döner. Normal oturum kurulmaz. `onDestroy` bu durumda başlatılmamış alanlara dokunmadan çıkar. Ek yoksa davranış değişmez.
5. **Testler:** `NetBenchTest` ayrıştırma, Mbps ve istatistiği kapsar. Ayrıca kısa süreli bir loopback testi (`ServerSocket`) down/up baytlarını ve başlığı doğrular. Sonra `./scripts/check.sh` çalıştırılır.

## Handoff

- **Commit:** `4a97d24` (uygulama), plan `4090399`. Dal `task/T-090-net-bench`, `main` 8ecd219 üstünde.
- **Dokunulan dosyalar:**
  - `bench/NetBench.kt` (yeni): `NetBenchConfig.parse`, `BenchDir`, `Throughput`, `ThroughputStats`.
  - `bench/NetBenchRunner.kt` (yeni): yalnız java.net kullanır.
  - `bench/NetBenchActivity.kt` (yeni).
  - `MainActivity.kt`: +11 satır. `net_bench` eki varsa ekleri `NetBenchActivity`'ye iletir ve `finish()` eder; `onDestroy` erken döner.
  - `AndroidManifest.xml`: `.bench.NetBenchActivity`, `exported=false`, yatay.
  - `test/.../bench/NetBenchTest.kt` (yeni, 10 test, loopback testleri dahil).
  - Bu kart.
- **check.sh:** ALL OK.
- **Davranış:**
  - Komut: `am start -n dev.matebridge.client/.MainActivity --es net_bench HOST:PORT [--ei net_bench_s 8] [--es net_bench_dir down|up|both] [--ei net_bench_streams 1..4] [--ei net_bench_rcvbuf_kb N]`.
  - Sınırlar: süre [1, 600] s. Bağlantı sayısı [1, 4], yön başına. Bilinmeyen yön `down` sayılır. `rcvbuf_kb` yalnız >0 ise `connect` öncesinde `setReceiveBufferSize` ile uygulanır, aksi halde dokunulmaz.
  - `both`, down için N, up için N bağlantı açar (toplam 2N).
  - **Bağlantı başına başlık:** bağlanınca tek satırlık ASCII başlık yazılır: `netbench dir=down|up stream=<i> secs=<S>\n`. Mac betiği bununla yönü ayırt edebilir. Okumazsa da sorun olmaz: down bağlantısında tablet başka hiçbir şey yazmaz, up bağlantısında ise bunlar yalnızca ilk ~35 bayttır.
  - Sonra down bağlantısı 256 KB tamponla okuyup atar. Up bağlantısı sürekli 64 KB sıfır tampon yazar.
  - Bağlantı zaman aşımı 3 s. Hata olursa `ev=error stage=connect err=<Sınıf>` loglanır ve ekranda kalır.
  - **Loglar (`MB/netbench`):**
    - `ev=start host=… port=… dir=… secs=… streams=… rcvbuf_kb=…`
    - Her bağlantı için `ev=connected dir=… stream=i rcvbuf=<uygulanan> sndbuf=…`
    - Her saniye, yön başına: `ev=tick dir=down mbps=123.4 bytes=<o saniye> ms=1000`
    - Sonda, yön başına: `ev=done dir=… streams=N secs=8.0 mbps_avg=… mbps_min=… mbps_max=… bytes=<toplam> ticks=8`
    - Karşı taraf erken kapatırsa: `ev=stream_end … reason=eof` ve gerekirse `ev=early_end`.
  - `mbps_avg` toplam bayt bölü toplam süredir; tick ortalamalarının ortalaması değildir. Mbps = 10^6 bit/s.
  - **Ekran:** siyah zemin üzerinde beyaz metin. Ölçüm sırasında "Ağ ölçümü… down X Mbps · up Y Mbps (k/S s)" gösterilir. Bitince "Ağ ölçümü bitti … ort/min/maks" ekranda kalır, uygulama kendiliğinden kapanmaz. Ekran açık tutulur.
  - Aktivite yok edilirse (geri tuşu) ölçüm iptal edilir ve soketler kapanır.
  - Bu kipte oturum, keşif (NSD) ve girdi yoktur. Ek parametre yoksa MainActivity eskisi gibi çalışır.
- **Varsayımlar:**
  - Başlık satırı kartta yoktu. `both` kipinde bağlantıları ayırt edebilmek için eklendi; Mac betiğinin buna uyması gerekir. Gerekirse başlık kaldırılabilir.
  - Up hızı, sokete kabul edilen bayt üzerinden ölçülür. Sonunda en fazla bir gönderme tamponu kadar fazla sayılabilir. Up için asıl ölçü Mac tarafında alınan bayttır.
  - Up yönünde, süre dolunca soketler doğrudan kapatılır (`close`). Mac tarafı bunu RST/EOF olarak görebilir.
  - Sonuç yalnız uygulama katmanı yükünü gösterir. Saniyelik zamanlama `Thread.sleep` ile yapılır ve gerçek geçen süre `ms=` alanında loglanır.
- **Test edilmeyenler / tablette doğrulanacaklar:**
  1. Önce `adb shell am force-stop dev.matebridge.client` çalıştırın (çalışan bir oturum varsa yeni MainActivity örneği onun üstüne açılır, eskisi `onStop` ile oturumu kapatır). Sonra Mac'te down için gönderici dinlesin. `am start -n dev.matebridge.client/.MainActivity --es net_bench <MacIP>:<port>` çalıştırın, `adb logcat -s 'MB/netbench:*'` ile izleyin. Beklenen: `ev=start` → `connected dir=down stream=0 rcvbuf=…` → 8 adet `tick` → `done dir=down … ticks=8`. Ekranda sonuç kalmalı, oturum/keşif logu (`MB/session ev=activity_start`) olmamalı.
  2. `--es net_bench_dir up` ve `--es net_bench_dir both --ei net_bench_streams 2`: Mac betiği başlıkla 2 down + 2 up bağlantıyı ayırmalı. Tablet `mbps` değerleri Mac'te ölçülen alma hızıyla kabaca tutmalı (up'ta son saniyede küçük fark olabilir).
  3. `--ei net_bench_rcvbuf_kb 4096`: `connected … rcvbuf=` değeri artmalı (HarmonyOS üst sınırı uygulayabilir, değer not edilmeli). Varsayılan çalışmada rcvbuf'ın küçük bir başlangıç değeri göstermesi normaldir, çünkü otomatik ayar açıktır.
  4. Yanlış adres/port: ekranda "bağlantı hatası" görünmeli ve `ev=error stage=connect` loglanmalı. Ek parametresiz normal açılışta oturum eskisi gibi kurulmalı.

