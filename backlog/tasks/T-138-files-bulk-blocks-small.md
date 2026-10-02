---
id: T-138
title: Dosyalar — Finder'ın video önizlemeleri tüm dosyayı indiriyor, küçük kopyalar "hazırlanıyor"da takılıyor
status: todo
phase: 5
owner: android-client-dev
depends_on: [T-137]
decisions: [0015]
files:
  - client-android/app/src/
  - host-mac/Sources/MateBridgeHost/Files/
  - host-mac/Sources/MateBridgeCore/Files/
  - host-mac/Tests/
  - tools/dav-repro/
  - backlog/tasks/T-138-files-bulk-blocks-small.md
---

## Amaç

Cihaz (2026-10-02 ~18:20): bağlama artık 0,17 s (T-137 tamam). Kullanıcı **141 KB** bir dosya kopyalamaya çalıştı; Finder "kopyalamaya hazırlanıyor"da kaldı. Aynı anda tablet dakikalarca kesintisiz ~20 MB/s gönderiyordu (`reqs=0`, `bytes_out≈20 MB`, `throttled_ms≈3700/s`; ~4,4 GB). `lsof -p <webdavfs_agent>`: `/private/tmp/.webdavcache.*/webdav.*` içinde **2,7 GB** önbellek dosyası. Finder `showIconPreview = 1`. Yani Finder/QuickLook klasördeki videoların önizlemesi için webdavfs **tüm dosyayı** indiriyor (webdavfs açılan dosyayı bütün olarak önbelleğe alır), hattı ve sunucuyu dolduruyor; küçük kopya arkada bekliyor.

## Kabul kriterleri

- [ ] **Tekrar üretim** (`tools/dav-repro`, JVM sunucu + gerçek NetFS bağlama, çalışan host'a ve `/Volumes/MatePad`'e dokunmadan): birkaç büyük (ör. 1–3 GB, seyrek/sahte) `.mp4` içeren klasör + Finder simge görünümü/QuickLook (`qlmanage -t` ile tetiklenebilir) + aynı anda küçük dosya kopyası (`cp`). Küçük kopyanın ne kadar beklediği ve neyi beklediği (sunucu bağlantı sınırı 4? token bucket'ta toplu aktarımın arkasında kalma? webdavfs_agent içi sıra?) kanıtla gösterilir.
- [ ] **Kök nedene göre düzeltme** (öneriler, kanıta göre seç):
  - sunucuda küçük/meta istekler (PROPFIND, küçük GET/PUT, LOCK…) toplu aktarımın arkasında beklemesin: ayrı/öncelikli bant ya da token bucket'ta öncelik; bağlantı sınırında küçük istekler için ayrılmış yer;
  - webdavfs'in tüm dosya indirmesi (ör. önizleme) sınırlanabiliyorsa (Range davranışı, yanıt başlıkları) araştır ve kanıtla;
  - host tarafında, bağlanan birim için Finder önizlemesini kapatmak gibi kullanıcı ayarlarını değiştiren çözümler **yapılmaz** (kullanıcının genel Finder ayarına dokunma); gerekiyorsa Handoff'ta öneri olarak yaz.
- [ ] Hedef: arka planda büyük önizleme indirmesi sürerken 141 KB'lık kopya < 2 s'de biter; görüntü akışı etkilenmez (toplam tavan aynı kalır).
- [ ] Testler + `./scripts/check.sh` geçiyor. Handoff'ta öncesi/sonrası ölçüm.

## Plan

(ajan doldurur)

## Handoff

(ajan doldurur)
