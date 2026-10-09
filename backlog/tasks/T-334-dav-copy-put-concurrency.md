---
id: T-334
title: WebDAV — eşzamanlı COPY/MOVE geri alması başka bağlantının başarılı PUT'unu silmesin
status: todo
phase: 7
owner: android-client-dev
depends_on: [T-288]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/files/DavHandler.kt
  - client-android/app/src/test/
  - backlog/tasks/T-334-dav-copy-put-concurrency.md
---

## Amaç

Astra xhigh incelemesi (2026-10-10, `docs/reviews/2026-10-10/astra-review.md` #1), orkestratör doğruladı.

- `DavServer` her bağlantıyı ayrı iş parçacığında çalıştırır.
- `moveOrCopy` var olan hedefi `aside` adıyla kenara alır ve doğrudan `d`'ye kopyalar. Başarısızlık ya da iptal durumunda `finally` bloğu `d`'de **o anda ne varsa** siler ve `aside`'ı geri koyar.
- Bu arada başka bir bağlantı aynı `d`'ye PUT yapıp 204 almışsa, o yükleme kaybolur.

Olasılık düşük (aynı yola eşzamanlı yazma gerekir), ama sonuç veri kaybı.

## Kapsam

1. Örtüşen yollardaki mutasyonlar (PUT, COPY, MOVE, DELETE, MKCOL) serileştirilir. Ata ve torun ilişkisi de örtüşme sayılır. Basit bir yol kilidi tablosu ya da tek mutasyon kilidi kullanılabilir. Okuma işlemleri (GET, PROPFIND) kilitlenmez.
2. Alternatif: COPY özel bir geçici ada kopyalanır ve `fs.replace` ile yerine konur. Geri alma yalnız bu işlemin kendi oluşturduğu nesneyi siler.
3. Seçilen yol *Plan* bölümüne yazılır.

## Kabul

- Bariyerle denetlenen bir test: COPY ortadayken PUT başarılı olur, COPY sonra başarısız olur ya da iptal edilir, PUT içeriği korunur.
- T-288 testleri geçmeye devam eder.
- `./scripts/check.sh` geçer.
- Dosya adları loglanmaz.

## Plan

## Handoff

## Open questions
