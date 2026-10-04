---
id: T-173
title: Version the measurement and soak scripts and add device-smoke.sh
status: done
phase: 6
owner: orchestrator
depends_on: [T-145, T-146]
decisions: []
files:
  - tools/measure/
  - tools/soak/
  - scripts/device-smoke.sh
  - docs/WORKFLOW.md
  - docs/NOTES.md
  - backlog/tasks/T-173-measurement-kit-smoke.md
  # added after review, approved by the orchestrator (2026-10-04): selftest in check.sh, __pycache__ ignore,
  # LOGGING skip_pct line fix
  - scripts/check.sh
  - .gitignore
  - docs/LOGGING.md
---

## Amaç

The power, refresh and fps tools used for the October measurements (`mbmon.sh`, `an.py`, `macmon.sh`, `macan.py`) lived only in scratch and are lost, and no single command records which build, codec, panel rate, mode and transport a number came from. Performance claims in NOTES are therefore hard to reproduce and easy to cherry-pick (single runs, filtered seconds). After this card the measurement and soak tools are versioned in the repo, and `scripts/device-smoke.sh` captures the build identity plus a 60 s numeric stats window in one command. T-127, T-174 and T-194 build on it.

Source: external architecture review 2026-10-03 (M07, D5, D10); verification: docs/reviews/2026-10-03/verify-E-measurement.md (W6, M07 measurement bullets, PF1), docs/reviews/2026-10-03/verify-H-hygiene.md (SOAK-1 tooling), docs/reviews/2026-10-03/coverage-audit.md (§4.3 merge: one card, one directory per purpose).

## Bağlam

**Evidence:**
- `scripts/` holds only `board.sh`, `bundle-host.sh`, `check.sh`, `codex-review.sh`, `install-apk.sh`, `make-mac-icon.swift`, `usb-mode.sh`. No smoke command exists.
- The recipes are described in NOTES: ~l.1070 (`mbmon.sh`: 1 Hz panel rate, temperature, frequency, CPU shares to `/data/local/tmp/mbmon.txt`; `an.py`: window summary of `MB/decoder recv` and AGP touch events) and ~l.1119 ("Ölçüm araçları scratch'teydi … kayboldularsa"). The power/fps method is in the T-140/T-141 sections around ~l.1060–1080.
- The precedent for versioned tools is `tools/pacing/` (`README.md`, `sim.py`, `gaps.py`, an anonymised timing-only CSV).
- The only soak evidence is a 30 min run on an old build (NOTES 2026-09-30). PLAN's exit criterion is a week of daily use.
- PF1 (verify-E): the 2026-10-03 drawing numbers were single runs filtered to dense seconds, the pattern M07 warns about. Hence the result-header and run-count rules below.
- Build identity comes from T-145 (host log/menu SHA) and T-146 (client log/settings SHA); this card reads them, it does not add them.

**Layout (coverage audit §4.3: E W6 and H SOAK-1 both recreated `mbmon.sh`/`macmon.sh` in different places; merged here):**
- `tools/measure/`: `mbmon.sh` (tablet 1 Hz sampler), `an.py` (tablet window summary), `macmon.sh` (host sampler), `macan.py` (host summary), `README.md` (recipes, result-header format).
- `tools/soak/`: tablet and host 60 s samplers and `summarize.py`. Reuse `tools/measure/` samplers where possible instead of copying them.
- `scripts/device-smoke.sh`: one command, read-only on both devices.

**Soak sampler content (H SOAK-1), every 60 s:**
- Host: RSS (`ps -o rss`), open files (`lsof -p <pid> | wc -l`), threads (`ps -M`).
- Tablet: PSS (`dumpsys meminfo dev.matebridge.client`), `/proc/<pid>/fd` count (via `run-as` if needed), threads grouped by name prefix (`ps -T -p <pid>`: `mb-ctl-read-*`, `mb-video-*`, `mb-audio-*`, `mb-decoder*`, …), codec instances (`dumpsys media.codec` / `dumpsys media.resource_manager`).
- Log event counts: `decoder_give_up`, `detach_slow`, `audio_previous_slow`, `pipeline_retry`, `release_all`, reconnects.

**Privacy (AGENTS.md):** the smoke and soak scripts must filter logs to numeric fields of known stats lines. No clipboard, key, text or file-name lines; no device serial numbers in committed output. Keycodes never appear.

**Rules:** bash and python3 stdlib only, so no decision record is needed (AGENTS.md "no dependencies without a decision"). Scripts must not install, change settings, or start/stop the apps; device tests stay one at a time (CLAUDE.md).

## Kapsam dışı

- CI (T-149) and instrumentation tests.
- Running the 8 h / one-week soak (T-194) and the optical test (T-174).
- New log fields in the apps (T-168, T-169, T-170, T-171 add those; the scripts read whatever exists and print `-` for missing fields).

## Kabul kriterleri

- [ ] `scripts/device-smoke.sh` prints: host and APK build SHA (T-145/T-146 log lines), host macOS version, tablet `ro.build.display.id`, decoder name (`ev=codec_start`), `stream_config`, panel Hz and `vsync_ms_p50`, stream mode and transport. It then collects 60 s of `MB/render ev=stats`, `MB/decoder ev=stats` and host `ev=latency`/`ev=stats` lines, keeps numeric fields only, and prints p50/p95 of the key fields to stdout.
- [ ] `tools/measure/` holds `mbmon.sh`, `an.py`, `macmon.sh`, `macan.py` and a `README.md` with the recipes, rewritten from the NOTES descriptions.
- [ ] `tools/soak/` samplers record the host and tablet values listed in *Bağlam* every 60 s, plus the log-event counts; `summarize.py` prints per-hour trends and slopes (RSS/PSS, fds, threads per prefix, codec instances).
- [ ] Every result header produced by the tools names: commit SHAs, macOS and HarmonyOS builds, codec, topology/transport, resolution, target and real Hz, bitrate, content, duration and run count (≥ 3 for any claim).
- [ ] [doc] `docs/WORKFLOW.md` gains one paragraph: how to run `device-smoke.sh` and the result-header rule.
- [ ] No clipboard, key, text or serial-number content in any script output (grep-check documented in the README); bash and python3 stdlib only.
- [ ] [device] One `device-smoke.sh` run over USB and one over Wi-Fi; the outputs (numbers only) are pasted into NOTES with build IDs.
- [ ] `bash -n` and `python3 -m py_compile` pass for all new scripts; `./scripts/check.sh` geçiyor.

## Plan

Eski araçlar kayıp (`~/.cache/matebridge-tools/` ve scratchpad'lerde `mbmon.sh`/`an.py`/`macmon.sh`/`macan.py` yok); NOTES tariflerinden ve LOGGING.md'deki satır biçimlerinden yeniden yazılır. Yalnız bash (macOS 3.2 uyumlu), tablette POSIX sh (toybox) ve python3 stdlib.

1. `tools/measure/mblog.py`: ortak kütüphane. Log satırı ayrıştırma (`<mono> <L> <comp> sid= gen= ev= k=v`, logcat threadtime/epoch önekleri), **gizlilik filtresi** (yalnız beyaz listedeki `(component, ev)` satırları; değerden yalnız sayı / `a/b/c` sayı demeti / `-`; kimlik alanları sıkı regex'le: sha, codec adı, boyut, mod kimlikleri; geri kalan her şey atılır), yüzdelik, sonuç başlığı (commit SHA'ları, macOS ve HarmonyOS build, codec, topoloji/taşıma, çözünürlük, hedef ve gerçek Hz, bit hızı, içerik, süre, tur sayısı; < 3 tur ise "iddia değil" uyarısı). Ham log diske hiç yazılmaz: filtre boru hattında çalışır.
2. `tools/measure/smoke.py` + `scripts/device-smoke.sh`: kimlik (host `app_start`/`profile`/`session_started`, tablet `app_start`/`profile`/`codec_start`/`stream_config`, `getprop ro.build.display.id`, `sw_vers`), sonra 60 s pencere (tablet `adb logcat -T 1` → fifo → filtre; host `host.log` bayt ofsetinden ekleneni okur, dönüşü (rotation) karşılar). Anahtar alanların p50/p95'i stdout'a. `--out DIR` yalnız filtrelenmiş dosyaları saklar. Salt okunur: kurmaz, ayar değiştirmez, uygulama başlatmaz/durdurmaz; HUAWEI olmayan cihazda tablet kısmını reddeder; seri numarası basmaz.
3. `tools/measure/mbmon.sh` (tablette çalışır, `/data/local/tmp/mbmon.txt`): 1 Hz panel hızı (Huawei `lcd_fps_scence` düğümü, yoksa SurfaceFlinger), sıcaklık bölgeleri, CPU/GPU frekansı, ham CPU tick'leri (sistem + istemci/surfaceflinger/codec/HAL/adbd/logd). `--soak`: 60 s'de PSS, fd (`run-as`), iş parçacığı adları (önek grupları), codec kaynak sayısı ve arka planda olay sayımı için `logcat -e`. `an.py`: pencere özeti (CPU payları /800, panel Hz dağılımı, sıcaklık, frekans; isteğe bağlı logcat ile `MB/decoder recv`/s, `vsync_ms_p50`, AGP `final lcd fps` ve dokunma olayları).
4. `tools/measure/macmon.sh` (host, 5 s; `top -l 2` ile CPU, `ioreg` GPU kullanımı, MateBridgeApp/WindowServer/`--proc` süreçleri; `--soak`: RSS, `lsof` fd, `ps -M` iş parçacığı, host.log olay artışları). `macan.py`: özet + isteğe bağlı host.log penceresi (`ev=latency`/`cadence`/`net ev=stats`).
5. `tools/soak/`: `tablet-soak.sh start|stop|pull|status` (mbmon.sh `--soak`'u tablete itip ayrık başlatır; `pull` filtreleyerek çeker), `host-soak.sh` (macmon.sh `--soak --interval 60` sarmalayıcısı), `summarize.py` (saatlik eğilimler ve eğimler: RSS/PSS, fd, önek başına iş parçacığı, codec örnekleri, olay sayıları, yeniden başlatmalar; hüküm yok).
6. `tools/measure/selftest.sh` + `tools/measure/testdata/` (sentetik, yalnız sayısal): `bash -n`, `sh -n`, `py_compile`, ayrıştırıcı/özet beklenen değerleri, gizlilik grep'i (pano/tuş/metin/seri/IP içeren sentetik satırların çıktıya sızmadığı).
7. `tools/measure/README.md` (tarifler, başlık biçimi, gizlilik grep kontrolü), `tools/soak/README.md` (kısa), `docs/WORKFLOW.md` bir paragraf.

Riskler: tablet düğüm yolları (`lcd_fps_scence`, termal bölge adları, `media.resource_manager` biçimi) cihazda doğrulanmadı → değer yoksa `-` ve README'de "cihazda doğrula". Canlı cihazda hiçbir şey çalıştırılmaz (orkestratör merge sonrası tek tek). `check.sh` kart dosyalarında değil; selftest elle çalıştırılır (Açık sorular).

## Handoff

- **Commit:** `ba56260` (uygulama; plan `8d1b680`; main'e rebase sonrası SHA'lar), inceleme düzeltmeleri ayrı commit (aşağıda). `./scripts/check.sh` ALL OK; `tools/measure/selftest.sh` ALL OK.
- **Dokunulan dosyalar:** `scripts/device-smoke.sh`; `tools/measure/` (`mblog.py`, `smoke.py`, `mbmon.sh`, `an.py`, `macmon.sh`, `macan.py`, `selftest.sh`, `README.md`, `testdata/` yalnız sentetik sayısal dosyalar); `tools/soak/` (`tablet-soak.sh`, `host-soak.sh`, `summarize.py`, `README.md`); `docs/WORKFLOW.md` ("Ölçüm" paragrafı); bu kart. `docs/NOTES.md`'ye dokunulmadı (cihaz çıktıları orkestratörün işi).
- **Varsayımlar:**
  - Eski araçlar hiçbir yerde yok (`~/.cache/matebridge-tools/` ve scratchpad'ler tarandı); NOTES tariflerinden ve LOGGING.md + kaynak koddaki satır biçimlerinden yeniden yazıldı.
  - Gizlilik: `mblog.py filter` boru hattında çalışır, ham log diske yazılmaz. Beyaz listedeki `(component, ev)` satırlarında yalnız sayısal değerler ve sıkı regex'li kimlik alanları kalır. Bunun yanında `--events` (yalnız olay adı) ve `--agp` (yalnız fps sayısı ve `touch`) kipleri var. İstemcinin decoder yaşam döngüsü satırlarında (`codec_start`, `give_up`, `detach_slow`) `sid=/gen=` yok; ayrıştırıcı bunu da kabul ediyor.
  - Gerçek Hz başlıkta istemcinin `vsync_ms_p50` medyanından çıkar (vekil değer). Panelin kendisi `mbmon.sh` ile okunur.
  - `tablet-soak.sh start`, `mbmon.sh`'yi `/data/local/tmp`'ye itip tablette ayrık (`setsid nohup`) çalıştırır. Uygulama kurulumu ya da ayar değişikliği değildir. `device-smoke.sh` hiçbir şey itmez.
  - Yüzdelikler doğrusal interpolasyonla hesaplanır. Smoke tablosu pencere değerlerinin dağılımını verir: tablet 10 s, host 1 s pencere. `enc_ms.p95` gibi alanlar host'un pencere başına yüzdeliğidir.
- **Test edilmeyenler / cihazda doğrulanacaklar:** Hiçbir şey canlı cihazda ya da canlı Mac'te çalıştırılmadı. Testler stub'larla yapıldı: adb/top/ioreg/ps/lsof/pgrep/sw_vers sahte, `/proc` ve `/sys` sahte ağaç, host.log geçici dosya. Cihazda bakılacaklar:
  - [device] kriteri: bir USB, bir Wi-Fi `device-smoke.sh` koşusu, çıktıları NOTES'a.
  - Huawei panel düğümü `/sys/class/graphics/fb0/lcd_fps_scence` var mı, biçimi `current_fps:N` mi (yoksa `panel_src=sf`)?
  - Termal bölge adları ve devfreq GPU düğümü.
  - `dumpsys media.resource_manager` biçimi (`codec_res` yalnız eğilim sayısı).
  - HarmonyOS'ta `logcat -e` ve `-f`; `run-as` ile fd sayımı; toybox `pgrep -f`, `setsid`.
  - `dumpsys meminfo` "TOTAL PSS:" satırı.
  - Gerçek `top -l 2` ve `ioreg` çıktısında `macmon.sh` ayrıştırması. Biçim yerelde bir kez salt okunur kontrol edildi, örnekleyici koşturulmadı.
  - logcat halkası döndüyse `apk_sha` `-` çıkar. README'de anlatıldı.
- **Codex incelemesi sonrası (5 × P2, aynı dal, main'e — T-225 dahil — rebase edildi):**
  1. `tablet-soak.sh pull`: iki aktarım da tabletteki bayt sayısıyla doğrulanıyor (olaylar için `mblog.py filter --bytes-to`). Sonuçlar `.part` + `mv` ile yazılıyor. Tablet dosyaları yalnız ikisi de başarılıysa siliniyor. Selftest: kesik aktarım başarısız oluyor, hiçbir şey silinmiyor, yarım dosya kalmıyor; tam aktarım siliyor.
  2. `tablet-soak.sh stop`: stop dosyası örnekleyicinin çıktığı görülene kadar kalıyor (30 s'den sonra "tekrar stop" uyarısı, dosya yerinde). Örnekleyici çıkarken dosyayı kendisi siler.
  3. `mbmon.sh`: ölçülemeyen değer artık `-`, sıfır değil: okunamayan pid grubu (`t_*`), başarısız ya da boş `run-as`/`ls` fd listesi, okunamayan thread adları (önce doğrudan, sonra `run-as` ile uygulama kimliğiyle), boş `dumpsys`, okunamayan frekans/sıcaklık. `summarize.py` `threads=-` örneklerini önek gruplarında sıfır saymıyor. Selftest: izinsiz fd/comm → `fds=- threads=-`, olmayan grup → `t_codec=-`.
  4. `macmon.sh`: `top -n 5000` (tüm süreçler). İzlenen süreç çalışmıyorsa `cpu_<ad>=-`, top başarısızsa `top_other_cpu=-`. Selftest `--proc Absent` → `-`.
  5. `macan.py`: dilim için ofsetlerin azalmadığı, `hl_ino` (macmon artık yazıyor) tek ve geçerli dosyanınkiyle aynı olduğu ve dosyanın yeterince uzun olduğu kontrol ediliyor; değilse nedenli uyarı. Selftest: geri giden ofset ve başka inode.
  - Onaylanan ek dosyalar: `scripts/check.sh` selftest'i tam koşuda çağırıyor (yalnız macOS'ta; Linux CI'da SKIP, araçlar BSD `stat`/`top` kullanıyor; hata olunca yalnız başarısız satırlar basılıyor). `.gitignore`'a `__pycache__/`. `docs/LOGGING.md`: `skip_pct` `render ev=stats` satırında (T-225 metni korundu).
  - Commit: bu Handoff güncellemesiyle aynı commit (aşağıdaki `git log`). `./scripts/check.sh` ALL OK (selftest dahil).
- **Açık sorular:**
  - İstemci `migrate_request` satırı uç nokta IP'sini logluyor (`host=`); filtre atıyor. Orkestratör ayrıca not edecek.
