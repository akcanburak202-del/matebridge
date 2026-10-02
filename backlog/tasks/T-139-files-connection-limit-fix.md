---
id: T-139
title: Dosyalar — bağlantı sınırı 8, yalnız gerçekten boştaki bağlantıyı düşür, ilerlemeyen yazımı kapat
status: in_progress
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

1. `FilesConfig`: `MAX_CONNECTIONS` 4 → 8; yeni ayarlar (testte kısaltılabilir): `evictIdleMs` (1 000), `overflowConnections` (4), `admitWaitMs` (2 000), `writeTimeoutMs` (30 000).
2. `DavServer` kabul kuralı:
   - Bağlantı yalnızca **gerçekten boştayken** tahliye edilebilir: en az bir isteği tamamlamış (`served`), istek başlığını bekliyor (`idle`, ilk bayt gelince — kova beklemesinden önce — `false`), ≥ `evictIdleMs` boşta ve soket tamponunda okunmamış bayt yok (`available()==0`). Yeni bağlantı ilk isteği bitene kadar asla tahliye edilmez → T-138 canlı kilidi biter.
   - Yumuşak sınırda (8) tahliye edilebilir bağlantı yoksa yeni bağlantı **beklemeden** taşma olarak kabul edilir (sert sınır 8+4=12; bellek ≤ 12×2×64 KB).
   - Sert sınırda: en eski gerçekten boştaki bağlantıyı düşür; yoksa ≤ `admitWaitMs` bekle, sonra `503 Service Unavailable` + `Retry-After: 1` + `Connection: close` (kısa ömürlü reddetme iş parçacığı, istek başlığını okuyup yanıtlar). Gerekçe: webdavfs kaynağı (`webdav_network.c` `translate_status_to_error`) 503'ü yeniden denemiyor, `ENOENT`'e çeviriyor → 503 yalnız son çare; normal yol taşma. Mac'te ölçülerek doğrulanır.
3. Yazma zaman aşımı: `WriteWatchdog` (saf, saat enjekte edilebilir) + tek izleyici iş parçacığı (hiç yazım yokken süresiz bekler, yoklama yok). `ThrottledOutputStream` her ham soket yazımını `begin/end` ile işaretler; kova beklemesi işaret dışında kalır. `writeTimeoutMs` boyunca biten yazım yoksa soket kapatılır, `write_stalled` loglanır.
4. JVM testleri: 4 uzun GET sürerken 5. ve 6. küçük istek < 1 s; yeni (isteksiz) bağlantılar birbirini tahliye etmez, sert sınırda 503 ≤ ~admitWait; boştaki bağlantı ≥ evictIdleMs sonra tahliye edilir; okunmayan yanıt kısa `writeTimeoutMs` ile kapanır; `WriteWatchdog` birim testleri.
5. `tools/dav-repro`: `DavRepro.java` yeni yapılandırıcı + ortam değişkenleri (`MB_DAV_OVERFLOW`). Mac ölçümü (UI yok): run8 (readers 4×2 GB) ve run6 yerine UI'siz `ql` tetiği (qlmanage -t, Finder'ın küçük resim yolu) — önce (cc65a9f) / sonra.

## Handoff

(ajan doldurur)
