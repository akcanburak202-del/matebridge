---
id: T-139
title: Dosyalar — bağlantı sınırı 8, yalnız gerçekten boştaki bağlantıyı düşür, ilerlemeyen yazımı kapat
status: todo
phase: 5
owner: android-client-dev
depends_on: [T-138]
decisions: [0015]
files:
  - client-android/app/src/
  - tools/dav-repro/
  - backlog/tasks/T-139-files-connection-limit-fix.md
---

## Amaç

T-138 araştırması (kart Handoff'u, `tools/dav-repro`): 4 uzun GET (webdavfs tüm dosya indirmesi, ör. Finder video küçük resmi) bağlantı sınırını (4) doldurunca `DavServer.admit()` yeni bağlantıları sonsuza kadar bekletiyor (küçük kopya hiç ulaşmıyor, Finder "beklenmedik hata", çıkarma "kullanımda"); bir yer boşken de yeni kabul edilmiş, başlığı henüz okunmamış bağlantılar "boşta" sayılıp birbirini düşürüyor (2 318–4 196 bağlantılık canlı kilit). Kullanıcı düzeltmeyi onayladı (2026-10-02).

## Kabul kriterleri

- [ ] `FilesConfig.MAX_CONNECTIONS` 4 → 8.
- [ ] Düşürme yalnızca **gerçekten boştaki** keep-alive bağlantıya: en az bir isteği tamamlamış, ≥ ~1 s yeni istek beklemede, okunmamış bayt yok. İlk isteği bitmemiş bağlantı asla düşürülmez. Boşta bağlantı yoksa yeni bağlantı sonsuza kadar bekletilmez: kısa süre (ör. ≤ 2 s) bekler, sonra `503 Service Unavailable` + `Retry-After: 1` ile kapatılır (webdavfs yeniden dener) — seçimini testle gerekçelendir.
- [ ] Yanıt yazımı ~30 s hiç ilerlemezse bağlantı kapatılır (yazma zaman aşımı; token bucket beklemesi "ilerleme yok" sayılmaz).
- [ ] Regresyon testleri (JVM): 4 uzun GET sürerken 5. ve 6. küçük istek < 1 s yanıt alır; yeni bağlantılar birbirini düşürmez (bağlantı sayısı sınırlı kalır); ilerlemeyen yazım 30 s'de (testte kısaltılabilir sabit) kapanır.
- [ ] `tools/dav-repro` ile Mac'te öncesi/sonrası (run8 ve run6 senaryoları) ölçülür, Handoff'a yazılır. **Arayüz yok:** `open`, Finder AppleScript, NetFS otomatik açma, Finder tetikleyicisi (`MB_BULK_ALLOW_UI`) **kullanılmaz** — Mac'in tek ekranı kullanıcının tableti.
- [ ] Toplam hız tavanı (20 MB/s) ve güvenlik modeli değişmez. `./scripts/check.sh` geçiyor.

## Plan

(ajan doldurur)

## Handoff

(ajan doldurur)
