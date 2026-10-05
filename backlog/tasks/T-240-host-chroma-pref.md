---
id: T-240
title: Host — apply STREAM_PREFS.chroma (decision 0033) via the T-235 sharp_nearest path; codec field rename
status: review
phase: 6
owner: mac-host-dev
depends_on: [T-235, T-237]
decisions: [0033]
files:
  - host-mac/Sources/MateBridgeCore/
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeHost/Session/
  - host-mac/Tests/
  - docs/LOGGING.md
  - docs/KNOBS.md
  - backlog/tasks/T-240-host-chroma-pref.md
---

## Amaç

Decision 0033'ün host tarafı. Protokol ve fixture'lar `task/T-239-chroma-protocol` dalında; **bu dalın üzerine kur** (`git checkout -b task/T-240-host-chroma task/T-239-chroma-protocol`). Protokolü değiştirme.

## Bağlam

- Codec: `STREAM_PREFS` grubundaki `reserved` → `chroma` (fixture `stream_prefs_hdr` alan adı değişti, bayt aynı; yeni `stream_prefs_sharp_chroma`). Bilinmeyen değer → 0. Yazma kuralı: grup `dynamic_range ≠ 0 || chroma ≠ 0` ise.
- Politika: `ChromaPolicy` girdi önceliği: env `MATEBRIDGE_CHROMA` > `STREAM_PREFS.chroma` (1 → `sharp_nearest`) > normal. HDR10 kuralı (T-237 birleşimi) aynen: HDR uygulanınca yok sayılır, `reason=hdr`.
- Değişim yeni `config_id` ile; ekran yeniden kurulmaz, yalnız yakalama biçimi + Metal geçişi değişir. Cihaz başına hatırlanan tercih `chroma`'yı da taşır (T-049 deposu).
- `ev=chroma_config` her yapılandırmada `source=env|prefs|default` ile; `ev=chroma_stats` yalnız keskin yol açıkken (bugünkü gibi).

## Kabul kriterleri

- [x] [XCTest] Fixture'lar (yeni + adı değişen), politika önceliği, HDR kuralı, hatırlanan tercih.
- [x] Varsayılan (chroma=0, env yok) yol T-235'teki varsayılanla bit-bit aynı.
- [x] `./scripts/check.sh --only host,protocol` geçer (Kotlin fixture testi T-241'de).

## Plan

1. **Codec (Core, `Messages.swift`):** `StreamPrefs.chroma: UInt8` (eski atlanan `reserved` bayt). Yazma: grup `dynamic_range ≠ 0 || chroma ≠ 0` ise (`dynamic_range`, `chroma`); okuma: baytı `chroma`'ya alır. `normalized`: bilinmeyen değer → 0. Yeni `ChromaPreference` (`normal=0`, `sharp=1`, `init(wire:)`, `logName`) ve `StreamPrefs.requestedChroma`.
2. **Ayar (Core, `VideoSettings` + `StreamPrefsPolicy`):** `VideoSettings.chromaPreference` (varsayılan `.normal`). `applying(_:)`: HDR10 uygulandıysa `.normal` (HDR'de etkisiz: tercih değişimi ayarları değiştirmez, boşuna yeniden yapılandırma yok; HDR geri dönüşü prefs'i HDR'siz yeniden uyguladığından SDR'ye düşünce keskin yol devreye girer), değilse `requestedChroma`. `displayMode` değişmez → ekran korunur, yalnız yakalama + kodlayıcı yeniden kurulur (mevcut `wanted != live.settings` → yeni `config_id` yolu).
3. **Politika (Core, `ChromaMode.swift`):** `ChromaSource` (`env|prefs|default`). `ChromaPolicy.resolve(knob:preference:codec:profile:dynamicRange:)`: knob tanımlıysa (geçersiz dahil, T-235 anlamı korunur) `env`; değilse `preference == .sharp` → `prefs`, istenen `sharp_nearest`; değilse `default` (`420`). HDR10 → `420`, `reason=hdr` (kaynak `default` değilse). `444` kuralları aynen. `ChromaDecision`'a `source` + `requested`; `logsEnabled` yerine `statsEnabled` (env tanımlı ya da uygulanan `sharp_*`). `ChromaConfigLog.line`'a `source=` (reason'dan sonra); satır her yapılandırmada yazılır.
4. **Hatırlanan tercih (Core, `StreamPrefsStore`):** kayıt `[fps, scale, bitrate, dw, dh, dynamic_range, chroma]`; 7. değer yalnız `chroma ≠ 0` iken (o zaman `dynamic_range` 0 da olsa yazılır). Eski kayıtlar (2/3/5/6) aynı okunur.
5. **Host:** `HEVCEncoder` çözümü `settings.chromaPreference` ile yapar; `chroma_config` her parametre seti duyurusunda (kaynakla), `chroma_stats` yalnız `statsEnabled`. Varsayılan yol (env yok, chroma=0): ProfileLevel, yakalama `420f`, dönüştürücü yok — T-235 varsayılanıyla aynı. `StreamCoordinator`: `stream_prefs`'e `chroma= requested_chroma=`, `stream_reconfigure`'a `chroma=<eski>-><yeni>`. `UserDefaultsStreamPrefsStore` belge yorumu.
6. **Belgeler:** `docs/LOGGING.md` (`chroma_config source=`, her yapılandırmada; `chroma_stats` koşulu; `stream_prefs`/`stream_reconfigure` alanları), `docs/KNOBS.md` #44 (env > `STREAM_PREFS.chroma`).
7. **XCTest:** fixture'lar (`stream_prefs_sharp_chroma` yeni, `stream_prefs_hdr` alan adı), codec yazma kuralı + bilinmeyen değer, politika önceliği (env > prefs > default), HDR kuralı, ayar türetme (HDR'de `.normal`, ekran modu aynı), hatırlanan tercih (store + `initialSettings`), varsayılan yolun eşitliği. `./scripts/check.sh --only host,protocol`.

## Handoff

- **Commit:** plan `65a4f49`; uygulama `1399147`; bu Handoff bir sonraki commit. Dal `task/T-240-host-chroma` (`task/T-239-chroma-protocol` üzerinde). Protokol/fixture değişmedi.
- **Dokunulan dosyalar:**
  - Core: `Messages.swift` (`StreamPrefs.chroma`, yazma/okuma, `normalized`, `requestedChroma`, yeni `ChromaPreference`), `Video/ChromaMode.swift` (`ChromaSource`, `ChromaDecision.source/requested/statsEnabled`, `ChromaPolicy.resolve(knob:preference:…)`, `ChromaConfigLog` `source=`), `Video/VideoSettings.swift` (`chromaPreference`), `Video/StreamPrefsPolicy.swift` (`applying`), `Video/StreamPrefsStore.swift` (7. değer).
  - Host: `Video/HEVCEncoder.swift` (çözüm tercihle; `chroma_config` her oturumda; stats `statsEnabled`), `Video/VideoPipeline.swift` (yorum), `Session/StreamCoordinator.swift` (`stream_prefs` `chroma= requested_chroma=`, `stream_reconfigure` `chroma=a->b`), `Session/UserDefaultsStreamPrefsStore.swift` (yorum).
  - Testler: yeni `Video/ChromaPrefsTests.swift` (12 test); `FixtureTests.swift` (`stream_prefs_sharp_chroma`, `stream_prefs_hdr` `chroma: 0`), `ChromaKnobTests.swift` (`source=env`, `statsEnabled`), `HDRTests.swift` (`statsEnabled`, mesaj), `GameDisplayTests.swift` (7 değer artık geçerli, geçersiz örnek 8 değer).
  - Belgeler: `docs/LOGGING.md` (bölüm başlığı + kaynak önceliği, `source=`, `stream_prefs`/`stream_reconfigure` alanları), `docs/KNOBS.md` #44.
- **Tasarım kararları / varsayımlar:**
  - Öncelik: `MATEBRIDGE_CHROMA` tanımlıysa (geçersiz değer dahil; T-235 anlamı: `420` + `reason=invalid_value`) `env` kazanır; `MATEBRIDGE_CHROMA=420` tablet tercihini kapatır. Değilse `chroma=1` → `sharp_nearest` (`source=prefs`), yoksa `default`.
  - HDR10'da `VideoSettings.chromaPreference` her zaman `.normal`: tercih değişimi HDR'de ayarları değiştirmez (boşuna `config_id`/yakalama yeniden başlatma yok; karar 0033 "etkisiz"). HDR geri dönüşü (`hdr_fallback`, `revalidated`) prefs'i HDR'siz yeniden uyguladığı için SDR'ye düşünce keskin yol devreye girer (test edildi). Bedeli: HDR + tablet tercihi `chroma_config`'te `source=default` görünür, `reason=hdr` yalnız env ile çıkar; tercih `stream_prefs requested_chroma=1 chroma=normal`'da görünür (LOGGING.md'de yazılı). `ChromaPolicy` tek başına çağrılırsa `preference: .sharp` + HDR → `reason=hdr source=prefs` (test edildi).
  - `chroma_stats`: env tanımlıyken (T-235'teki gibi, `420` tabanı dahil) ya da uygulanan mod `sharp_*` iken. Tablet tercihiyle Metal kurulamazsa (`metal_unavailable`) stats yok, `chroma_config` `W`.
  - `chroma_config` artık varsayılan yolda da her parametre seti duyurusunda bir `I` satırı (`requested=420 applied=420 source=default …`) yazar; SPS ayrıştırması yalnız o anda (oturum başına ~1 kez). Video yolu (ProfileLevel çağrısı, `420f` yakalama, dönüştürücü yok, stats yok) T-235 varsayılanıyla aynı (`testDefaultPathIsUnchanged`: karar `ChromaDecision(knob: .unset, applied: .yuv420, reason: nil)` ile eşit).
  - Yalnız `chroma` değişimi: `displayMode` aynı → `DisplayReuse` `.reuse`, mevcut `wanted != live.settings` yolu yeni `config_id` + `STREAM_CONFIG` (içerik aynı, yalnız id) + video kapatma; yakalama biçimi kodlayıcının uyguladığı moddan (`capturePixelFormat`).
  - Kayıt: `[fps, scale, bitrate, dw, dh, dynamic_range, chroma]`; `chroma ≠ 0` iken 7 değer (o zaman `dynamic_range` 0 da olsa yazılır). Eski build 7 değerli kaydı yok sayar (mod varsayılanı; T-237'deki 6 değer kuralıyla aynı).
- **Test edilmeyenler (cihaz / orkestratör):**
  - Canlı host'ta tablet `chroma=1` gönderince: `stream_prefs chroma=sharp requested_chroma=1` → `stream_reconfigure … chroma=normal->sharp` (`display_recreate` olmamalı) → `encoder ev=chroma_config requested=sharp_nearest applied=sharp_nearest source=prefs … chroma_loc=1` ve 10 sn'de `video ev=chroma_stats mode=sharp_nearest`. Kapatınca `chroma=sharp->normal`, `source=default`. İstemci T-241 gerektirir.
  - Yeniden bağlanınca hatırlanan tercihle doğrudan keskin yol (`stream_session from_stored=true`, ilk `STREAM_PREFS` değişiklik yapmamalı).
  - HDR10 + tercih açık: `chroma_config … applied=420 source=default`, `stream_prefs … chroma=normal requested_chroma=1`; toggle'da yeniden yapılandırma olmamalı.
  - Gerçek SCK `BGRA` yakalaması / Metal geçişi T-235 cihaz denemesinde (2026-10-05) çalıştı; burada yeniden denenmedi.
- **Açık sorular:**
  - HDR'de tablet tercihinin `chroma_config`'te `reason=hdr source=prefs` olarak görünmesi istenirse, ham tercihin `VideoSettings` eşitliğinin dışında taşınması gerekir (şimdilik `stream_prefs` satırında). Orkestratör karar verir.
  - `docs/KNOBS.md` #44'ün son sütunu ("kart B (karar)") eski; karar 0033 verildi, satırın "kalıcı mı" sütunu orkestratörce güncellenebilir.
