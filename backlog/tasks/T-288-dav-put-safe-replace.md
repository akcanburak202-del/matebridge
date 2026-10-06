---
id: T-288
title: İstemci — WebDAV PUT değiştirmesi başarısız olunca hiçbir sürümü silme
status: todo
phase: 6
owner: android-client-dev
depends_on: []
decisions: [0035]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/files/DavHandler.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/files/
  - backlog/tasks/T-288-dav-put-safe-replace.md
---

## Amaç

Astra incelemesi 2026-10-07, bulgu 1 (`docs/reviews/2026-10-07/astra-review.md`). `DavHandler.put` var olan dosyanın üzerine yazarken ilk `tmp.renameTo(target)` başarısız olursa önce `target.delete()` çağırıyor, sonra yeniden adlandırmayı tekrar deniyor. İkinci deneme de başarısız olursa `finally` geçici dosyayı siliyor ve iki sürüm de kayboluyor. Olasılık düşük ama sonuç veri kaybı. USB ve Wi-Fi dosyaları aynı yolu kullanıyor.

## Kabul

1. Değiştirme mümkünse atomik yapılır: `Files.move(tmp, target, REPLACE_EXISTING, ATOMIC_MOVE)`; desteklenmiyorsa `ATOMIC_MOVE` olmadan. Geri dönüş yolu eski dosyayı silmez, yedek adına taşır. Yeni dosya yerine geçince yedek silinir; geçemezse yedek geri taşınır.
2. Hiçbir hata yolunda hem eski hem yeni içerik birlikte kaybolmaz. Geri alma da başarısız olursa yüklenen geçici dosya silinmez; 500 döner ve log yazılır (dosya adı loglanmaz, `docs/LOGGING.md`).
3. Testler: başarısız yeniden adlandırma enjekte edilir (dosya sistemi soyutlaması ya da test kancası); eski içerik korunur. Başarılı değiştirmede 204, yeni dosyada 201 değişmez.
4. Geçici ve yedek dosyalar PROPFIND listesinde görünmez (mevcut `TEMP_PREFIX` kuralı).

## Plan

## Handoff

## Open questions
