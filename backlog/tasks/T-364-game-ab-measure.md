---
id: T-364
title: Ölçüm — oyun modu A/B kaydı (bit hızı, renk, çözünürlük): game-ab.sh + game_ab.py
status: review
phase: 7
owner: mac-host-dev
depends_on: [T-173]
decisions: []
files:
  - tools/measure/game-ab.sh
  - tools/measure/game_ab.py
  - tools/measure/mblog.py
  - tools/measure/selftest.sh
  - tools/measure/testdata/
  - tools/measure/README.md
  - backlog/tasks/T-364-game-ab-measure.md
---

## Amaç

`docs/research/2026-10-23-game-modes.md` → "Ölçüm planı": Oyun 60'ta dönüşümlü A/B (A1 bit hızı 60 ↔ 30 Mbps, A2 renk Keskin ↔ Normal, A3 1848 ↔ 2240, A4 2800 tek kol). Kullanıcı ayarı panelden değiştirir, orkestratör her kolu tek komutla kaydeder. Bu kart yalnız **araç**; cihaz oturumunu orkestratör kullanıcıyla yapar.

Mevcut kit (`tools/measure/README.md`, T-173) yeniden kullanılır: `mblog.py filter` (gizlilik), `macmon.sh` (Mac CPU/GPU), sonuç başlığı kuralı. Yeni bir şey icat etme; eksik olan kol başına kayıt + karşılaştırma tablosu.

## Kabul

1. `tools/measure/game-ab.sh LABEL --arm ARM --seconds N --out DIR [--proc "Oyun adı"] [--content TEXT]`:
   - Aynı anda: tablet logcat (filtreli, `mblog.py filter --side tablet`), `macmon.sh` (5 sn, `--proc` ile oyun süreci), host.log'un pencere dilimi (başlangıç/bitiş bayt konumu; dilim de filtreden geçer). N sn sonra hepsini durdurur, `DIR/LABEL/ARM-<k>/` altına yalnız filtreli dosyalar yazar (`k` aynı kolun kaçıncı tekrarı, kendiliğinden artar).
   - Salt okur: kurulum yapmaz, ayar değiştirmez, uygulama başlatmaz/durdurmaz (README "Recipes" kuralı). Tablet yoksa ya da HUAWEI değilse tablet kısmını atlar ve söyler.
   - Kolun gerçekten uygulandığını loglardan doğrular ve özetin başına yazar: uygulanan bit hızı (`stream_config`/host `encoder profile`), renk (host'un uyguladığı chroma; hangi satırda olduğu bulunur), ekran boyutu, kare hızı, taşıma. Uyuşmazlık `arm_check: MISMATCH (...)` olarak görünür; kayıt yine tutulur.
2. `tools/measure/game_ab.py summary DIR/LABEL` kol başına şu satırları verir (değer yoksa `-`):
   - host: gönderilen Mbps, `cap_fps` p50, `enc_ms` p50, `gpu_ms` p50/p95 (`ev=latency`), `cap_to_sent` p50/p95, video bağlantısı `ev=tcp conn=video` `retx_pkts_delta` toplamı ve >0 olan saniyelerin yüzdesi, `srtt_ms` p50/p95, `keyframe_request` sayısı;
   - tablet: alınan fps, `skip_pct` ortanca, çözme p50/p95, yakalama→çözme (ya da en yakın uçtan uca alan) p50/p95/p99, **takılma sayısı** (>150 ms). Takılmanın tanımı kartın Plan bölümüne yazılır: 2026-10-20 TotK analizinde hangi alan kullanıldıysa (NOTES 2026-10-20 22:30 "cap_dec_ms > 150"), o. Yalnız 10 sn pencere varsa en büyük değerden sayılır ve özet bunu söyler;
   - Mac: `gpu_dev` p50, MateBridgeApp / WindowServer / VTEncoderXPCService / oyun CPU p50.
   - Son blok: aynı LABEL'daki kollar yan yana (ARM başına tüm tekrarların ortancası **ve** min–max yayılımı), README sonuç başlığıyla. "3 kol altı" koşullar `claim_ok: no` ile işaretlenir.
3. Gizlilik: `mblog.py filter` allowlist'ine yalnız gereken satırlar eklenir (host `net ev=tcp`, `video ev=latency` alanları zaten sayısal; renk/bit hızı kimlik anahtarları sıkı desenle). README'deki gizlilik grep'i çıktılarda boş döner.
4. `selftest.sh`: sentetik `testdata/` ile iki kol × iki tekrar → beklenen özet; MISMATCH durumu; gizlilik grep'i. Cihaza dokunmaz.
5. README'ye "5. Oyun A/B (T-364)" tarifi: kol sırası A B A B A B, kol başına 90–120 sn, ayar değişiminden sonra ~10 sn bekleme (yakalama/kodlayıcı yeniden başlar; çözünürlükte ekran yeniden kurulur, oyun kendi çözünürlüğünü yeniden seçmek zorunda kalabilir).
6. `./scripts/check.sh` geçer (selftest dahilse).

## Plan

- `mblog.py`: filtre izin listesine yalnız gerekenler: host `net ev=tcp` (`conn=control|video`, `transport`), `net ev=keyframe_request` (`action`, `view`), `encoder ev=chroma_config` (`requested`, `applied`), `video ev=chroma_stats` (`mode`). Yeni kimlik anahtarları sıkı desenli.
- `game-ab.sh`: tablet kimliği (logcat -d) + host kimliği (host.log geçmişi, en yeni satır) → pencere: `macmon.sh` (5 sn, `--proc VTEncoderXPCServ` + oyun, `top` adı 16 karaktere kesilir) ve tablet logcat arka planda, host.log pencere dilimi bayt konumundan; hepsi `mblog.py filter`'dan geçer. `DIR/LABEL/ARM-K/` altına yalnız filtreli dosyalar. Tablet yoksa/HUAWEI değilse tablet kısmı atlanır ve söylenir.
- `game_ab.py arm|summary`: kol raporu (başlık, `arm_check`, uygulanan değerler, metrikler) ve LABEL'daki kolların yan yana tablosu (tekrarların ortancası + min-max; 3 tekrar altı `claim_ok: no`).
- `arm_check`: `--expect` anahtarlarını (bitrate_kbps, chroma, width, size, fps, transport) loglardan okunan uygulanmış değerlerle karşılaştırır. Bit hızı: tablet `session profile` + host `encoder profile`; renk: pencere içindeki `chroma_stats mode`, yoksa son `chroma_config applied`; boyut/fps/taşıma: tablet `session profile`. Uyuşmazlık `MISMATCH`, kayıt kalır. Pencerede `profile` satırı çıkarsa uyarı.
- **Takılma tanımı:** NOTES 2026-10-20 22:30 ile aynı: host `net ev=stats` 1 Hz örneklerinde `cap_dec_ms` > 150 olan saniye sayısı. O alan yoksa tablet 10 sn pencerelerinde `cap_dec_max_us` > 150000 olan pencere sayısı (alt sınır; özet kaynağı söyler).
- Test: `testdata/game_ab/` sentetik; `selftest.sh` iki kol x iki tekrar, MISMATCH, takılma yedeği, profil uyarısı, tabletsiz kayıt, gizlilik grep'i.

## Handoff

- Commit: c8520d31 (branch `task/T-364-game-ab-measure`; bu Handoff ayrı bir küçük commit). `./scripts/check.sh` ALL OK (selftest dahil).
- Dosyalar: `tools/measure/game-ab.sh`, `game_ab.py` (yeni), `mblog.py` (izin listesi), `selftest.sh`, `README.md` (tarif 5), `testdata/game_ab/*` (sentetik), bu kart. Kart ana çalışma ağacında izlenmiyordu; dala kopyalandı.
- Varsayımlar: (1) takılma = host `net ev=stats` 1 Hz `cap_dec_ms` > 150 (NOTES 2026-10-20 22:30); alan yoksa tablet 10 sn `cap_dec_max_us` > 150000 pencere sayısı. (2) Tablet decode p95 loglanmıyor (`dec_p50_us` var, p95 yok): "çözme p50/p95" host'un 1 Hz `decode_ms` örneklerinden; 10 sn satırı yalnız p50. (3) Yakalama→çözme p99 de 1 Hz örneklerden; tablet 10 sn p50/p95 ayrı satır. (4) `gpu_ms`/`enc_ms`/`cap_to_sent_ms` satırları 1 sn host pencerelerinin p50/p95 değerlerinin ortancası. (5) Düz 4:2:0 için `chroma_stats mode=420` varsayıldı (LOGGING "420'de dönüşüm yok" diyor, satırın yazılıp yazılmadığı gerçek logda görülmedi); yoksa son `chroma_config applied` kullanılır. (6) `top` komut adını 16 karaktere keser (bu Mac'te `VTEncoderXPCServ` görüldü); script `--proc` adlarını da keser. (7) Kol sırası `start_ep` ile belirlenir (komut bitiş saati - süre).
- Gizlilik: allowlist'e yalnız `net tcp` (conn, transport), `net keyframe_request` (action, view), `encoder chroma_config` (requested, applied), `video chroma_stats` (mode); `action` deseni genişledi (forced|coalesced|config_resent|aux_only). Gerçek host.log'a yalnız okuma bakışı; ham satır depoya girmedi.
- Test edilmedi / cihazda doğrulanacak: gerçek tabletle `logcat` akışı ve `session ev=profile` alanlarının (size/bitrate/transport) çalışan uygulamada beklenen biçimde olması; oyun sürecinin `top` adı; `--expect chroma=...` karşılaştırmasının gerçek `chroma_stats mode` değerleriyle (özellikle Normal kolunda); Wi-Fi'de video `ev=tcp` satırlarının gerçekten geldiği; 100 sn'lik gerçek pencerede macmon örnek sayısı (5 sn x 20). Hiçbir cihaza dokunulmadı.

## Open questions

- Tablet tarafı decode p95'i loglamıyor; A3 karar kuralı ("çözme p95 < 16,7 ms") için 1 Hz `decode_ms` p95 kullanılıyor. Tablet kodunda `dec_p95_us` istenirse ayrı kart.
