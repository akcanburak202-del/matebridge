---
id: T-240
title: Host — apply STREAM_PREFS.chroma (decision 0033) via the T-235 sharp_nearest path; codec field rename
status: in-progress
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

- [ ] [XCTest] Fixture'lar (yeni + adı değişen), politika önceliği, HDR kuralı, hatırlanan tercih.
- [ ] Varsayılan (chroma=0, env yok) yol T-235'teki varsayılanla bit-bit aynı.
- [ ] `./scripts/check.sh --only host,protocol` geçer (Kotlin fixture testi T-241'de).

## Plan

1. **Codec (Core, `Messages.swift`):** `StreamPrefs.chroma: UInt8` (eski atlanan `reserved` bayt). Yazma: grup `dynamic_range ≠ 0 || chroma ≠ 0` ise (`dynamic_range`, `chroma`); okuma: baytı `chroma`'ya alır. `normalized`: bilinmeyen değer → 0. Yeni `ChromaPreference` (`normal=0`, `sharp=1`, `init(wire:)`, `logName`) ve `StreamPrefs.requestedChroma`.
2. **Ayar (Core, `VideoSettings` + `StreamPrefsPolicy`):** `VideoSettings.chromaPreference` (varsayılan `.normal`). `applying(_:)`: HDR10 uygulandıysa `.normal` (HDR'de etkisiz: tercih değişimi ayarları değiştirmez, boşuna yeniden yapılandırma yok; HDR geri dönüşü prefs'i HDR'siz yeniden uyguladığından SDR'ye düşünce keskin yol devreye girer), değilse `requestedChroma`. `displayMode` değişmez → ekran korunur, yalnız yakalama + kodlayıcı yeniden kurulur (mevcut `wanted != live.settings` → yeni `config_id` yolu).
3. **Politika (Core, `ChromaMode.swift`):** `ChromaSource` (`env|prefs|default`). `ChromaPolicy.resolve(knob:preference:codec:profile:dynamicRange:)`: knob tanımlıysa (geçersiz dahil, T-235 anlamı korunur) `env`; değilse `preference == .sharp` → `prefs`, istenen `sharp_nearest`; değilse `default` (`420`). HDR10 → `420`, `reason=hdr` (kaynak `default` değilse). `444` kuralları aynen. `ChromaDecision`'a `source` + `requested`; `logsEnabled` yerine `statsEnabled` (env tanımlı ya da uygulanan `sharp_*`). `ChromaConfigLog.line`'a `source=` (reason'dan sonra); satır her yapılandırmada yazılır.
4. **Hatırlanan tercih (Core, `StreamPrefsStore`):** kayıt `[fps, scale, bitrate, dw, dh, dynamic_range, chroma]`; 7. değer yalnız `chroma ≠ 0` iken (o zaman `dynamic_range` 0 da olsa yazılır). Eski kayıtlar (2/3/5/6) aynı okunur.
5. **Host:** `HEVCEncoder` çözümü `settings.chromaPreference` ile yapar; `chroma_config` her parametre seti duyurusunda (kaynakla), `chroma_stats` yalnız `statsEnabled`. Varsayılan yol (env yok, chroma=0): ProfileLevel, yakalama `420f`, dönüştürücü yok — T-235 varsayılanıyla aynı. `StreamCoordinator`: `stream_prefs`'e `chroma= requested_chroma=`, `stream_reconfigure`'a `chroma=<eski>-><yeni>`. `UserDefaultsStreamPrefsStore` belge yorumu.
6. **Belgeler:** `docs/LOGGING.md` (`chroma_config source=`, her yapılandırmada; `chroma_stats` koşulu; `stream_prefs`/`stream_reconfigure` alanları), `docs/KNOBS.md` #44 (env > `STREAM_PREFS.chroma`).
7. **XCTest:** fixture'lar (`stream_prefs_sharp_chroma` yeni, `stream_prefs_hdr` alan adı), codec yazma kuralı + bilinmeyen değer, politika önceliği (env > prefs > default), HDR kuralı, ayar türetme (HDR'de `.normal`, ekran modu aynı), hatırlanan tercih (store + `initialSettings`), varsayılan yolun eşitliği. `./scripts/check.sh --only host,protocol`.

## Handoff

_(Ajan bitirince doldurur.)_
