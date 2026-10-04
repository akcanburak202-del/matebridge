---
id: T-231
title: Black level lifted on the tablet — client dev knobs to override colour range/standard/transfer and a logged output-format report (A/B on device)
status: review
phase: 6
owner: android-client-dev
depends_on: []
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/DevKnobs.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - docs/LOGGING.md
  - backlog/tasks/T-231-client-color-override-knobs.md
---

## Amaç

Belirti ve ölçüm T-230 Amaç bölümünde (Mac 0,0,0 → tablet 16,16,16; beyaz doğru). Tablet ACodec: `color aspects (R:1(Full), P:1(BT709_5), M:1(BT709_5), T:2(SRGB)) dataspace 0x201`. İstemci `VideoRenderer.kt:367-369` STREAM_CONFIG'den `KEY_COLOR_STANDARD/TRANSFER/RANGE` koyuyor; SurfaceView'a MediaCodec doğrudan çıkış veriyor (T-184).

Orkestratörün cihazda A/B yapabilmesi için geliştirici düğmeleri (decision 0026 sınıfı, `--ez dev true` kapısı arkasında, varsayılan davranış değişmez):

- `--es color_range auto|full|limited|unset`: `KEY_COLOR_RANGE` ezilir (`unset` = anahtar hiç konmaz).
- `--es color_standard auto|bt709|bt601|unset`, `--es color_transfer auto|srgb|sdr_video|unset`: aynı mantık.
- Çözücü `INFO_OUTPUT_FORMAT_CHANGED` aldığında çıkış biçimindeki `color-range/standard/transfer` ve varsa `hdr-static-info`'yu bir `ev=decoder_output_format` satırıyla logla (bir kez/format değişiminde).

İzin verilen değerler `Spec.ids` ile sınırlı (log güvenliği, DevKnobs düzeni).

## Kabul kriterleri

- [x] [JVM] Düğme ayrıştırma: her değer → beklenen MediaFormat davranışı; `dev` kapısı yokken yok sayılır (`ignored=` listesinde).
- [x] [JVM] Varsayılan (düğme yok) yol bit-bit aynı MediaFormat anahtarlarını koyar.
- [x] `ev=decoder_output_format` docs/LOGGING.md'de.
- [x] `./scripts/check.sh` geçer. APK kurma, tablete dokunma: cihaz A/B'sini orkestratör yapar.

## Plan

1. **Saf mantık** `video/ColorOverrides.kt`: `ColorOverrides(range, standard, transfer)`; her biri `AUTO` (bugünkü `ColorMapping` eşlemesi), sabit bir değer ya da `UNSET` (anahtar hiç konmaz). Değerler: range `full=1 limited=2`; standard `bt709=1 bt601=4` (`ColorMapping` NTSC sabiti ile aynı); transfer `sdr_video=3`, `srgb=2` (ColorUtils'in gizli `kColorTransferSRGB`; public MediaFormat'ta yok, ACodec `T:2(SRGB)` buna karşılık). `parse(raw?)`: bilinmeyen/yok → `auto` (DecoderLatencyKnobs düzeni). `standard(config)/transfer(config)/range(config): Int?` (null = koyma). `AUTO` sabiti = bugünkü davranış.
2. **DevKnobs**: `color_range`, `color_standard`, `color_transfer` STRING Spec'leri, `debugOnly=true`, `ids` = izinli kimlikler (log güvenliği); `colorOverrides` alanı. `dev` yoksa `ignored=` listesine düşer, `knobs=` içinde `color_range:<id>` olarak görünür.
3. **VideoRenderer**: yeni yapıcı parametresi `colorOverrides: ColorOverrides = ColorOverrides.AUTO`; `decoderFormat` içindeki üç renk satırı aynı sırada `colorOverrides.*(config)` ile yazılır (AUTO → bit-bit aynı). T-217 geri düşüş formatı da aynı renk ezmesini kullanır (renk düğmesi gecikme geri düşüşünden bağımsız).
4. **`ev=decoder_output_format`**: saf `OutputFormatReport.fields(view, requested)`: çıkış formatından `range/standard/transfer` (yoksa `unset`), `hdr_static_info=<hex>|unset` (en çok 64 bayt), ve configure'a verilen `req_range/req_standard/req_transfer`. `DecoderCodec.FormatView`'a varsayılanı null olan `getByteBuffer` eklenir (MediaCodecDecoder'da gerçek). Çıkış iş parçacığı her `INFO_OUTPUT_FORMAT_CHANGED` görülen drain'den sonra yazar; codec başına aynı satır tekrarlanmaz, üst sınır 16. Mevcut `ev=output_format` (codec başına bir kez) değişmez.
5. **MainActivity**: `colorOverrides = devKnobs.colorOverrides` VideoRenderer'a geçer.
6. **Testler (JVM)**: ColorOverrides ayrıştırma + her değerin MediaFormat davranışı (FakeDecoderFactory configure formatı üzerinden); varsayılan yol bugünkü anahtar listesine bit-bit eşit; DevKnobs kapısı (`ignored=`, `knobs=`, `other`); OutputFormatReport alanları; fake'e çıkış formatı değişimi betiği eklenip satırın format değişiminde yazıldığı ve tekrarın bastırıldığı test edilir.
7. `docs/LOGGING.md`: `ev=decoder_output_format` ve düğmeler. `./scripts/check.sh`.

## Handoff

- **Commit:** `c61dce1` (uygulama; plan `951e7d1`), dal `task/T-231-color-knobs`. `./scripts/check.sh`: ALL OK.
- **Dosyalar:**
  - yeni `client-android/app/src/main/kotlin/dev/matebridge/client/video/ColorOverrides.kt` (`ColorOverrides`, `OutputFormatReport`, `OutputFormatLogGate`)
  - `video/VideoRenderer.kt` (`colorOverrides` parametresi, `colorKeys()`, `ev=decoder_output_format`), `video/DecoderCodec.kt` (`FormatView.getByteBuffer`, varsayılan null)
  - `session/DevKnobs.kt` (`color_range/standard/transfer` Spec'leri, `colorOverrides`), `MainActivity.kt` (VideoRenderer'a geçiş)
  - test: yeni `video/ColorOverridesTest.kt`; `video/FakeDecoderCodec.kt` (çıkış formatı değişimi betiği), `session/DevKnobsTest.kt`
  - `docs/LOGGING.md` (dosya sonuna yeni bölüm)
- **Varsayımlar:**
  - `srgb` = 2 (`ColorUtils::kColorTransferSRGB`, gizli platform kodu; MediaFormat bunu ColorAspects'e geçirir). `bt601` = 4 (`COLOR_STANDARD_BT601_NTSC`, `ColorMapping` ile aynı).
  - Renk ezmesi T-217 geri düşüş formatında da geçerli. Renk anahtarı configure'da reddedilirse (beklenmez) geri düşüş de aynı anahtarla başarısız olur ve olağan `decode_error` yolu işler; renk için ayrı bir geri düşüş yok.
  - `req_*` alanları configure'a verilen değerlerdir (codec'in `inputFormat`'ı değil).
  - Eski `ev=output_format` satırı olduğu gibi kaldı; yeni satır her format değişiminde (aynı alanlar tekrarlanmaz, codec başına ≤16).
- **Test edilmeyen:** hiçbir şey cihazda denenmedi. MediaCodec'in `srgb=2` ya da `unset` ile configure'u kabul edip etmediği, `hdr-static-info`'nun HiSilicon'da gelip gelmediği bilinmiyor.
- **Tablette denenecek (orkestratör, sırayla, Mac'te siyah tam ekran):**
  1. Ayarsız açılış: `ev=decoder_output_format gen=1 … req_range=1 req_standard=1 req_transfer=3` gelmeli, `ev=codec_start` ve görüntü T-231 öncesiyle aynı.
  2. `--ez dev true --es color_range limited`: siyahın 16→0'a inip inmediği (ve beyazın kırpılıp kırpılmadığı); `decoder_output_format range=` değeri.
  3. `--ez dev true --es color_range unset --es color_standard unset --es color_transfer unset`: VUI'ye bırakınca siyah; çıkış formatındaki değerler.
  4. `--ez dev true --es color_transfer srgb` ve `sdr_video` karşılaştırması; `--es color_standard bt601` (renk kayması beklenir, yalnız matris doğrulaması).
  5. `dev` olmadan aynı ayarlar: `diag ev=dev_knobs ignored=color_range,…` ve davranış değişmemeli; `ev=profile knobs=` `dev` ile `color_range:<id>` göstermeli.

## Open questions

- `docs/KNOBS.md` envanterine (karar 0026) `color_range/color_standard/color_transfer` satırı eklenmeli; dosya bu kartın `files:` listesinde olmadığı için dokunulmadı (orkestratör).
- `docs/LOGGING.md`'de "Decoder gecikme anahtarları" bölümünün son maddeleri ve "Kodlayıcı donanım denetimi" bölümü iki kez geçiyor (önceden var olan kopya); dokunulmadı.
