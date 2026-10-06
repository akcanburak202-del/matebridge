---
id: T-280
title: Client — HDR anahtarı Günlük modunda da (mod başına ayrı ayar)
status: in_progress
phase: 6
owner: android-client-dev
depends_on: []
decisions: [0032, 0033, 0034]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - backlog/tasks/T-280-hdr-daily-mode.md
---

## Amaç

Karar 0032 güncellemesi (2026-10-06): film ve video izlemek için HDR anahtarı **Günlük** modunda da olsun. Bugün yalnız Oyun'da var (`HdrPolicy.dynamicRange`/`rowHidden` → `mode.isGame`). Host ve protokol değişmez: host `dynamic_range`'i moddan bağımsız uygular.

## Kabul

1. **Mod başına ayrı, kalıcı ayar:** Oyun'un mevcut ayarı (`hdrGame`) aynen kalır, kayıtlı değer taşınır. Günlük için ayrı yeni ayar eklenir, varsayılan **Kapalı**. Oyun'da açık HDR, Günlük'e geçince uygulanmaz; tersi de geçerli. Çizim'de satır gizli, istek SDR.
2. `HdrPolicy.dynamicRange` HDR10'u şu koşulların hepsi tutunca ister: yetenek var + mod Günlük ya da Oyun + **o modun** ayarı açık. `rowHidden` yalnız Çizim'de true. Panel satırı ve "Uygulanan: HDR10/SDR" bilgisi Günlük'te de görünür. Yetenek yoksa bugünkü gibi gri "(Bu cihazda yok)".
3. Satır, değeri o anki modun ayarından okur ve değişikliği o moda yazar. Akış sırasında değişim bugünkü yolla `STREAM_PREFS` gönderir. Mod değişince istek yeni modun ayarına göre yeniden hesaplanır.
4. Günlük + HDR10 uygulanınca renk satırı bugünkü gibi gri "(HDR açıkken etkisiz)" olur (0033/0034). Tam renk tercihi silinmez; HDR kapanınca geri gelir.
5. `ev=hdr_request` alanları değişmez (`mode=` zaten var). "Varsayılanlara dön" iki HDR ayarını da Kapalı yapar. Mevcut "HDR yalnız Oyun" yorumlarını ve KDoc'u güncelle.
6. JVM testleri: Günlük açık → HDR10, Günlük kapalı/Oyun açık → Günlük'te SDR, Çizim hep SDR, yeteneksiz hep SDR, satır görünürlüğü, mod başına okuma/yazma, varsayılanlara dönüş, eski kayıtlı Oyun değerinin korunması.
7. `./scripts/check.sh`. Tablete dokunma, Mac'te pencere açma.

## Plan

## Handoff

## Open questions
