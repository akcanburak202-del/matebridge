---
id: T-288
title: İstemci — WebDAV PUT değiştirmesi başarısız olunca hiçbir sürümü silme
status: done
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

1. `DavHandler` alır bir `DavFs` (replace / rename / delete; varsayılan gerçek dosya sistemi). Testler hata enjekte eder.
2. PUT'un son adımı `commit(tmp, target)`: önce `Files.move(REPLACE_EXISTING, ATOMIC_MOVE)` (yalnız atomik; `ATOMIC_MOVE` desteklenmezse de istisna yedek yoluna düşer, çünkü atomik olmayan move Unix'te hedefi önce siler). Reddedilirse eski dosya silinmez, gizli `.mbput-*.tmp` yedek adına taşınır; yükleme yerine geçerse yedek silinir, geçmezse yedek geri taşınır (500).
3. Geri alma da başarısız olursa geçici yükleme silinmez (yedek de durur), `ev=put_replace_failed restored=0` loglanır (ad yok), 500 döner. İkisi de `.mbput-` öneki yüzünden PROPFIND'da görünmez.
4. Testler `DavPutReplaceTest`: başarılı 201/204, reddedilen replace yedek yoluyla başarı, yeniden adlandırma hatasında eski içerik geri, yedekleme hatası, geri alma hatasında iki içerik de diskte ve listede yok, eksik hedef.

## Handoff

- Commit: `task/T-288-dav-put-safe-replace` dalının tek commit'i ("T-288: ...").
- Dosyalar: `client-android/app/src/main/kotlin/dev/matebridge/client/files/DavHandler.kt` (yeni `commit`, `DavFs` arayüzü + `DavFs.Default`, yapıcıya `fs` parametresi), `client-android/app/src/test/kotlin/dev/matebridge/client/files/DavPutReplaceTest.kt` (6 test, handler doğrudan çağrılır, soket yok), bu kart.
- `./scripts/check.sh`: ALL OK.
- Varsayımlar: `java.nio.file.Files` minSdk 29'da var. Hedef yoksa ve replace başarısızsa geri alınacak bir şey yok: 500, geçici dosya silinir. Geri almada `rename(backup, target)` iki kez denenir.
- Tablette kontrol: normal dosya yükleme/üzerine yazma (Finder'dan aynı adlı dosyayı kopyala): 201/204 değişmemeli, klasörde `.mbput-*` artığı kalmamalı. Gerçek hata yolu cihazda tetiklenemez (yalnız birim testle kapsanır).
- Test edilmeyen: gerçek FUSE/sdcard üzerinde `ATOMIC_MOVE` davranışı.

## Open questions

- `docs/LOGGING.md` "Tablet dosya sunucusu" bölümüne `ev=put_replace_failed restored=0|1` satırı eklenmeli (dosya kartın `files:` listesinde olmadığı için dokunmadım; orkestratör ekler).
