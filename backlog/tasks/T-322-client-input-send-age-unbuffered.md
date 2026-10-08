---
id: T-322
title: Tablet — girdi gönderim yaşı istatistiği (EN1) ve parmak/trackpad/fare için tamponsuz dağıtım anahtarı (EN3)
status: review
phase: 7
owner: android-client-dev
depends_on: []
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/input/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - backlog/tasks/T-322-client-input-send-age-unbuffered.md
---

## Amaç

T-298 `docs/reviews/2026-10-08/agents/opt-c-e2e.md` EN1 ve EN3. Wi-Fi'de host `input_age` p50: işaretçi 16,4 ms, tuş 12,8 ms. RTT ~5 ms çıkarılınca 8–10 ms tablet ya da host'ta. Trackpad yaşı p50 15,4 ms (2026-10-08). Tamponsuz dağıtım bugün yalnız kalemde (`UnbufferedPenDispatch`).

## Kabul

1. **EN1:** `MB/input ev=stats` satırına sınıf başına (kalem, işaretçi, tuş, kaydırma) `send_age_ms_p50/p95/max` eklenir: soket yazımının döndüğü an − `eventTime`, tablet saatiyle. Yalnız sayı ve süre; koordinat ya da karakter yok. Önerilen LOGGING metni Handoff'a.
2. **EN3:** `--es unbuffered_src off|touch|all` (varsayılan `off`, `--ez dev true` arkasında).
   - `touch`: `SOURCE_TOUCHSCREEN` için `requestUnbufferedDispatch`.
   - `all`: ek olarak `SOURCE_MOUSE | SOURCE_TOUCHPAD` (ve pointer capture'daki göreli kaynak).
   - Kalem davranışı değişmez. Etkin kaynaklar `ev=unbuffered` logunda görünür.
3. **Girdi güvenliği:** bırakma yolları ve `SendQueue` birleştirme (`POINTER_REL` coalescing) değişmez. Olay sayısı artarsa kuyruk sınırlı kalır; testle göster.
4. **Testler:** yaş istatistiği (yüzdelikler, sınıf ayrımı), anahtar ayrıştırma ve kaynak maskesi.
5. **Cihaz A/B (orkestratör):** trackpad 30 sn `off` / `all`, host `input_age pointer_p50` ve yeni `send_age`.

## Plan

- EN1: `SendQueue` girdi mesajini sinif + olay zamani ile damgalar (`ControlLink.send`); yazici thread soket `write+flush` donunce `SendAgeStats.record(...)` (System.nanoTime, eventTime ile ayni saat). `SendAgeStats` sabit bellekli histogram (250 us kova, 4096 kova), sinif basina p50/p95/max. `InputCapture` ozet satirina her pencerede ekler (`sendAgeFields`).
- EN3: `--es unbuffered_src off|touch|all` (`DevKnobs`, debug-only, varsayilan off). `UnbufferedSources` tek `requestUnbufferedDispatch` maskesini uretir (kalem her zaman var). Pen yolu/`SendQueue` birlestirme/birakma yollari degismedi.

## Handoff

- Commit: f7b9403758df663fe199b85272d325edf3da2f05 (branch task/T-322-input-age; bu satirin guncellenmesi sonrasi ek commit).
- Dosyalar: `input/SendAgeStats.kt` (yeni), `input/UnbufferedSources.kt` (yeni), `input/InputCapture.kt` (sendAgeFields), `input/UnbufferedPenDispatch.kt` (sourcesLabel), `session/SendQueue.kt` (damga, takeStamped), `session/SessionController.kt` (writerLoop kaydi, `takeSendAgeFields`), `session/DevKnobs.kt` (`unbuffered_src`), `MainActivity.kt` (maske + baglanti); testler: `SendAgeStatsTest`, `UnbufferedSourcesTest`, `SendQueueStampTest`, `DevKnobsTest`, `UnbufferedPenDispatchTest` (log metni).
- check.sh: ALL OK.
- Varsayimlar: yas = soket `flush()` dondugu an - mesaj olay zamani (PEN icin son ornegin zamani; birlestirilen mesajda en yeni olay). Olay zamani ms cozunurluklu (`eventTime*1000`). Sinif: pen=Pen; pointer=PointerAbs/PointerRel/Pinch; key=Key; scroll=Scroll. PenGesture/ReleaseAll/diger kaydedilmez. Kova 250 us: p50/p95 kova ust siniri (en fazla +0,25 ms), max tam. Sifreleme (`sealFrame`) yazma oncesinde oldugu icin yasa dahil.
- `ev=unbuffered` logu artik `path=source sources=stylus|stylus+touch|stylus+touch+mouse+touchpad+mouse_rel` (yalniz metin eki; eski `path=source` onegi ayni). Host/mblog betikleri tam satir eslestiriyorsa kontrol edilmeli (tools/ bu kartin disinda, bakilmadi).
- `ev=profile knobs=` listesine `unbuffered_src:off|touch|all|other` eklenir (yalniz anahtar verilmisse).
- Onerilen `docs/LOGGING.md` metni (`MB/input ev=stats` satirina ek): "T-322: `pen_send_n= pen_send_age_ms_p50= pen_send_age_ms_p95= pen_send_age_ms_max=` ve ayni uc alan `pointer_`, `key_`, `scroll_` onekleriyle; yalniz penceredeki mesajlar icin, verisi olmayan sinif yazilmaz. Yas = soket yazimi dondugu an - olay zamani, tablet saati, ms (bir ondalik). Kova cozunurlugu 0,25 ms. Veri olan bir pencerede girdi sayaci 0 olsa bile satir yazilir." ve `ev=unbuffered`: "`sources=` etkin kaynaklar (`unbuffered_src`, T-322)". `docs/KNOBS.md`: `unbuffered_src off|touch|all` (debug-only, varsayilan off).
- Tablette test EDILMEDI (adb kullanilmadi). Orkestrator kontrol listesi:
  1. `am start ... --ez dev true` (unbuffered_src yok): `MB/input ev=unbuffered` `sources=stylus`, `ev=stats` satirlarinda `*_send_age_ms_*` gorunur; yazim/klavye/trackpad sirasinda makul degerler (beklenen kucuk, tek haneli ms).
  2. `--es unbuffered_src all` ile trackpad 30 sn; `off` ile ayni; host `input_age pointer_p50` ve `pointer_send_age_ms_p50` kiyasla. `ev=unbuffered` `sources=stylus+touch+mouse+touchpad+mouse_rel`.
  3. `touch` ile parmak surukleme/kaydirma: olay sayisi (`touch_msgs`) artisi, `refused=0`, baglanti dususu yok.
  4. Kalem davranisi `off` ile onceki gibi (max_batch ~1).
  5. Pointer capture acik/kapali gecis, arka plana alma: takili tus/dugme yok.

## Open questions
