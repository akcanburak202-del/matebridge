---
id: T-294
title: Tablet — kare gelmeyen video bağlantılarında yeniden açma geri çekilmesi; "manual" durumda 10 sn'de bir kendiliğinden dönüş
status: todo
phase: 6
owner: android-client-dev
depends_on: [T-291]
decisions: [0019]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionMachine.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoHealth.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/session/
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/
  - backlog/tasks/T-294-client-video-retry-backoff.md
---

## Amaç

T-291 tasarım notu, "Tablet" bölümü (`backlog/tasks/T-291-rebuild-budget-with-client-ladder.md`). Host'un video bağlantısını kalıcı hatada hemen kapatması (T-293) karşısında tablet 500 ms'de bir yeniden bağlanıyor. Ayrıca host düzelse bile `manual` durumdaki tablet, "Yeniden dene"ye basılmadan görüntüye dönmüyor (`videoFlowing` → `resume_skipped`).

## Kabul

1. **Geri çekilme:** üst üste 3 video bağlantısı hiç VIDEO_FRAME almadan kapanırsa sonraki yeniden açma beklemesi 500 ms → 1 → 2 → 4 sn olur (tavan 4 sn).
   - Sayaç ilk VIDEO_FRAME'de ve "Yeniden dene"de sıfırlanır.
   - İlk 3 deneme bugünkü gibi 500 ms'dir; olağan yeniden bağlanma ve göç gecikmez.
   - "Yeniden dene" bağlantısı `SessionMachine`'e ulaşmıyorsa, nasıl bağladığını Handoff'ta yaz (kapsam dışı dosya gerekirse dur, *Open questions*'a yaz).
2. **Manual'dan dönüş:** `manual` durumunda `videoFlowing` (`VIDEO_LOST` FAULT'ta) en çok 10 sn'de bir `RESTART_CODEC` döndürür ve `step=manual_resume` loglar. `MAX_RESUMES` (manual dışında) ve bayat bağlantı kuralı değişmez.
   - Resume yeni bir kuşak başlatır; ilk çözülmüş çıktıya kadar STARTING'dedir ve girdi kapalıdır (0019).
   - Kuşak HEALTHY olunca katman kalkar ve 10 sn sağlıklı kalınca bölüm biter. Bunları testle göster.
3. Log: `video_retry backoff_ms= empty=` yalnız geri çekilme basamağı değişince yazılır.
4. Birim testleri:
   - geri çekilme basamakları ve sıfırlama (kare, yeniden dene);
   - ilk 3 denemede 500 ms;
   - manual'da 10 sn hız sınırı;
   - manual resume → STARTING → HEALTHY → katman kalkar;
   - bayat bağlantı hâlâ yok sayılır.
5. Girdi kapısı, `RELEASE_ALL` dizisi ve protokol değişmez.

## Plan

## Handoff

## Open questions
