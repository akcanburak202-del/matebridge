---
id: T-366
title: Ölçüm — video bağlantısına yapay takılma (dummynet) ve 30 ↔ 60 Mbps IDR zinciri A/B'si
status: review
phase: 7
owner: mac-host-dev
depends_on: [T-364]
decisions: []
files:
  - tools/measure/stall-inject.sh
  - tools/measure/game_ab.py
  - tools/measure/selftest.sh
  - tools/measure/testdata/
  - tools/measure/README.md
  - backlog/tasks/T-366-video-stall-injector.md
---

## Amaç

NOTES 2026-10-23 öğleden sonra: Wi-Fi aksamasında host kuyruğunda kare düşüyor → host IDR zorluyor → 170–250 KB IDR'ler tıkalı bağlantıya → 1–5 sn boyunca saniyede 1–3 IDR, tablette 13–41 fps. Kararlı durumda 4 bölüm 30 Mbps'te, 0 bölüm 60 Mbps'te; n küçük. Soru: aynı takılma iki bit hızında farklı mı sonuç veriyor? Doğal Wi-Fi aksaması beklenemez; Mac tarafında tekrarlanabilir takılma gerekiyor.

Hipotezler (ölçüm ayırt etmeli):
- H1 rastlantı: aynı takılma 30 ve 60'ta aynı IDR sayısı ve toparlanma süresini verir.
- H2 göreli IDR boyu: 30'da IDR / ortalama kare oranı büyük (~3,2 vs ~2,4) → toparlanma 30'da uzun.
- H3 TCP penceresi: düşük uygulama hızında `snd_cwnd` küçük kalır → takılma anındaki cwnd ile toparlanma süresi ilişkili.

## Kabul

1. `tools/measure/stall-inject.sh --port <video_port> --stall-ms N --every-s S --count K [--dir out]`:
   - macOS `dnctl` + `pfctl` (dummynet) ile **yalnız** Mac → tablet yönünde, yalnız verilen TCP kaynak portunda (host video portu, varsayılan 47002; gerçek port `HELLO_ACK.video_port`, host.log'dan okunur ve yazdırılır) her S saniyede bir N ms boyunca bant genişliğini ~0'a indirir (ya da eşdeğeri), sonra serbest bırakır. Kontrol (47001) ve ses etkilenmez.
   - `sudo` gerektirir; betik bunu açıkça ister ve root değilse hiçbir şey yapmadan çıkar. Her takılmanın başlangıç zamanını (host saatiyle karşılaştırılabilir, epoch ms) bir dosyaya yazar.
   - **Temizlik garantisi:** çıkışta, Ctrl+C'de ve hata durumunda kendi pf anchor'unu ve dummynet borusunu kaldırır; mevcut pf kurallarına dokunmaz (ayrı anchor; pf zaten kapalıysa sonunda eski durumuna döndürür). `--cleanup` tek başına kalıntıyı temizler. Kurulu kuralları göstermek için `--status`.
   - `--dry-run`: root olmadan çalıştırılacak komutları yazar (selftest bunu kullanır).
2. `game_ab.py`: kayıt klasöründe takılma zamanları dosyası varsa, her takılma için olay penceresi raporu: takılmadan sonraki 5 sn'de IDR sayısı, `queue_drops`/`overwritten`, `cap_dec_ms` en büyük, `cap_dec_ms` < 30 ms'ye dönüş süresi (toparlanma), takılma anındaki `snd_cwnd`/`unacked`; kol başına ortanca + min–maks. `summary` bu satırları kolları yan yana gösterir.
3. `selftest.sh`: sentetik veriyle olay penceresi raporu; `stall-inject.sh --dry-run` çıktısı (anchor adı, port, yön) beklenen komutları içerir. Cihaza ve pf'ye dokunmaz.
4. README tarifi: oturum sırası (60/30 dönüşümlü, kol başına 100 sn, 10 sn'de bir 60 ms takılma → kol başına ~9 olay), güvenlik notu (oturum sonunda `--status` boş olmalı).
5. Ajan `sudo` çalıştırmaz, pf/dnctl'ye gerçek kural yüklemez, uygulamaları açıp kapamaz, Mac'te pencere açmaz. Cihaz koşusunu orkestratör kullanıcıyla yapar.
6. `./scripts/check.sh` geçer.

## Plan

1. `stall-inject.sh`: tek dosya, bash. Her takılma = `dnctl pipe P config bw 8Kbit/s` ... `bw 0`'a geri (boru kalır, kurallar yerinde; yalnız bant genişliği oynar). pf kuralı `com.apple/matebridge-stall` anchor'unda (macOS varsayılan pf.conf zaten `dummynet-anchor "com.apple/*"` ve `anchor "com.apple/*"` içerir; ana kural kümesine dokunulmaz): `dummynet out proto tcp from any port <video_port> to any pipe P`. pf'yi `pfctl -E` ile açar (belirteç saklanır), çıkışta `pfctl -X belirteç` (eski durum geri gelir). Durum dosyası `/var/tmp/matebridge-stall.state` (belirteç, boru no); `--cleanup` bundan ve sabit isimlerden temizler (idempotent). trap EXIT/INT/TERM/HUP.
2. Zaman damgası: host.log'un `mono_ms` değeri `DispatchTime.now().uptimeNanoseconds/1e6` (mach uptime). Betik her takılmanın başında `python3 -I` ile `time.clock_gettime_ns(CLOCK_UPTIME_RAW)` (aynı saat) ve epoch ms alır; `stalls.txt` satırı: `stall n= epoch_ms= mono_ms= end_mono_ms= ms= port=`. host.log'da epoch yok, bu yüzden eşleştirme monotonla.
3. `--dry-run`: root'suz, hiçbir şey çalıştırmadan komutları yazar; port host.log'dan okunur (son `session_started video_port=`, yoksa 47002).
4. `game_ab.py`: arm klasöründeki `stalls.txt` için olay penceresi (takılma sonrası 5 sn host 1 Hz örnekleri): idr toplamı (`net stats idr`), `queue_drops` / `overwritten` (`video cadence`, pencere başına değer, toplanır), `cap_dec_ms` en büyüğü, <30 ms'ye dönüş süresi (sonraki takılmaya / 30 sn'ye kadar bakılır), takılma anındaki video `snd_cwnd` ve `unacked_bytes`. `arm` raporu olay tablosu + olaylar üzerinden ortanca (min-maks); `summary` kolları yan yana, olaylar kolun tüm tekrarlarında havuzlanır.
5. `selftest.sh`: sentetik `testdata/game_ab_stall/` (host.txt + stalls.txt) ile beklenen sayılar; `stall-inject.sh --dry-run` çıktısı (anchor, port, yön, boru); root değilken gerçek modun reddi. `README.md`: tarif 6.


## Handoff

Commit: `git log task/T-366-video-stall-injector -1` (SHA orkestratore bildirildi).

Dosyalar: `tools/measure/stall-inject.sh` (yeni), `tools/measure/game_ab.py`, `tools/measure/selftest.sh`, `tools/measure/README.md` (tarif 6), `tools/measure/testdata/game_ab_stall/` (sentetik b30-1 / b60-1), bu kart.

Yapilanlar:
- `stall-inject.sh`: dummynet boru 4700 (`bw 0` <-> `8Kbit/s`, kuyruk 100), kural `dummynet out proto tcp from any port <video_port> to any pipe 4700`, anchor `com.apple/matebridge-stall` (stok pf.conf `com.apple/*` anchor'unu zaten degerlendirir; mevcut kurallara dokunulmaz). `pfctl -E` belirteci `/var/tmp/matebridge-stall.state`'te; cikis/INT/TERM/HUP/hata trap'i anchor + boru + `pfctl -X` yapar. `--cleanup`, `--status` (sonda `status: clean`), `--dry-run` (root'suz, hicbir sey calistirmaz/yazmaz). Root degilse gercek mod hicbir sey degistirmeden cikar. Video portu host.log'daki son `session_started video_port=`, yoksa 47002; `--port` ezer, uyumsuzlukta uyarir.
- Zaman: host.log `mono_ms` = `DispatchTime.uptimeNanoseconds/1e6` (mach uptime); betik ayni saati `time.clock_gettime_ns(CLOCK_UPTIME_RAW)` ile alir. `stalls.txt`: `stall n= epoch_ms= mono_ms= end_mono_ms= ms= port=`. host.log'da epoch yok, eslestirme monotonla (epoch da yaziliyor).
- `game_ab.py`: arm klasorunde `stalls.txt` varsa olay bolumu (arm: olay tablosu + ortanca (min-maks); summary: kollar yan yana, kolun tum tekrarlari havuzlanir). Satirlar: idr, queue_drops, overwritten (5 sn toplam), cap_dec_ms en buyuk, <30 ms'ye donus (sonraki takilmaya/30 sn'ye kadar; donmeyen olay `recovered n/N` ile sayilir), takilma oncesi son video `ev=tcp`'den snd_cwnd/unacked (KB).
- selftest: dry-run komutlari (anchor, port, yon, boru), --port uyarisi, kontrol portu yok, gecersiz arguman, root'suz ret, sentetik olay sayilari.

Varsayimlar: `queue_drops` / `overwritten` `video ev=cadence` satirinda saniye basina deger (toplanir); `idr` `net ev=stats`'ta onceki satirdan beri sayi. Pencere (m0, m0+5 s] 1 Hz orneklerle; ilk ornek takilmadan onceki <=1 sn'yi de kapsar. Kart `game-ab.sh`'i `files:` disinda biraktigi icin stalls.txt'yi kullanici `--dir` ile arm klasorune yazdirir (README tarifi).

Gercek Mac'te DOGRULANMADI (hicbir pf/dnctl komutu calistirilmadi): pf/dummynet soz dizimi ve `com.apple/` anchor'unun degerlendirilmesi, `pfctl -E` cikti bicimi (`Token : n`), `dnctl list` bicimi (`04700:`), `bw 0` = sinirsiz, 8 Kbit/s + kuyruk 100 ile 60 ms'nin gercek takilma yaratmasi. Ilk kosuda once `--dry-run`, sonra `--count 1` + `--status`.

check.sh: swift build/test, protocol, crypto, measurement selftest OK. `gradle (client-android)` KIRMIZI: AacDecodeWorkerTest, DecoderWaitTest ("output polls 7"), OutputParkTest (zamanlama testleri). Bu dal client-android'e dokunmuyor; makine yuku yuksekti (load 4-7); iki kosuda ayni 3 test. Main'de de kirmizi mi orkestrator dogrulamali.

## Open questions
