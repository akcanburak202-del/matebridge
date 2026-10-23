---
id: T-366
title: Ölçüm — video bağlantısına yapay takılma (dummynet) ve 30 ↔ 60 Mbps IDR zinciri A/B'si
status: todo
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

(ajan doldurur)

## Handoff

## Open questions
