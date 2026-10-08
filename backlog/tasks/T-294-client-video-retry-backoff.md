---
id: T-294
title: Tablet — kare gelmeyen video bağlantılarında yeniden açma geri çekilmesi; "manual" durumda 10 sn'de bir kendiliğinden dönüş
status: done
phase: 6
owner: android-client-dev
depends_on: [T-291]
decisions: [0019]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionMachine.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoHealth.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionController.kt  # (T-294 review, orchestrator)
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt  # (T-294 review, orchestrator) only the retry handler call
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/Latest.kt  # (T-294 review, orchestrator) one mail slot
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

1. `SessionMachine`: `videoEmptyCloses` sayacı; `VideoClosed`'da bağlantı kare almadıysa artar, aldıysa sıfırlanır. Kare gözlemi `Tick(videoFrames)` sayacından: bağlantı açılırken sayaç kaydedilir, sonraki tick'te artmışsa ilk kare gelmiştir (sayaç hemen sıfırlanır). Bekleme `videoRetryDelayUs(n)`: n<=3 → 500 ms, sonra 1/2/4 sn (tavan 4 sn). `video_retry` logu yalnız basamak değişince.
2. `VideoHealth.videoFlowing`: `manual` durumda 10 sn hız sınırıyla `RESTART_CODEC` (`step=manual_resume`); `MAX_RESUMES` ve bayat bağlantı kuralı aynı.
3. Birim testleri: `VideoRetryBackoffTest` (yeni), `VideoHealthTest` (manual resume, hız sınırı, bayat).

## Handoff

- Commit: `git log task/T-294-video-retry-backoff` (tek T-294 commit'i).
- Dosyalar: `SessionMachine.kt`, `VideoHealth.kt`, `session/VideoRetryBackoffTest.kt` (yeni), `session/VideoLossGateTest.kt` (eşik 10 → 8 yeniden açma: geri çekilme 20 sn'de 9 açma bırakıyor), `video/VideoHealthTest.kt`.
- check.sh: ALL OK.
- Varsayımlar:
  - "İlk 3 deneme 500 ms" = ardışık 1., 2., 3. boş kapanıştan sonraki bekleme 500 ms; 4. → 1 sn, 5. → 2 sn, 6.+ → 4 sn.
  - Kare gözlemi 500 ms'lik Tick sayacından gelir; bağlantı son tick'ten sonra kare alıp hemen kapanırsa boş sayılır (en çok 500 ms hata, yalnız 3+ ardışık durumda etki eder).
  - Sayaç oturumlar arasında korunur (host devre kesicisinin tekrar eden oturumlarına karşı); yalnız kare ile sıfırlanır.
- **"Yeniden dene" sıfırlaması bağlanmadı:** `MainActivity` düğmesi `VideoHealth.retry()` çağırıyor, `SessionMachine`'e hiçbir olay gitmiyor. Sıfırlama için `MainActivity`/`SessionController` değişmeli (kapsam dışı). Etki: kullanıcı basınca tablet en çok 4 sn'lik basamakta kalır; ilk kare gelince zaten sıfırlanır.
- Girdi kapısı, `RELEASE_ALL` ve protokol değişmedi.
- Tablette bakılacaklar:
  1. Host video bağlantısını kalıcı reddederken (T-293) log: `video_retry backoff_ms=1000 empty=4` -> 2000 -> 4000, sonra sabit.
  2. `manual` katmanında host düzelince en çok 10 sn içinde `step=manual_resume`, katman kalkar, girdi ilk çözülmüş çıktıdan sonra açılır.
  3. Normal yeniden bağlanma/göç sırasında `video_retry` logu görünmemeli.
  4. Sağlıklı oturumda davranış değişmemeli.

- **Review turu (Codex, ikinci commit):**
  - P1: `VideoHealth` soğuma süresinde gelen ilk kareyi `pendingResumeConn` olarak hatırlar; `tick()` süre dolunca `RESTART_CODEC` (`step=manual_resume`) döndürür. O/sonraki bağlantının `videoLost`'u, Detached ve kullanım temizler; hâlâ 10 sn'de en çok bir resume.
  - P2: `SessionController` okuyucu iş parçacığı bağlantının ilk karesini görünce `Event.VideoFirstFrame(gen)` gönderir (`videoFirstFrame` posta kutusu, `videoClosed`'dan önce alınır) ve `VideoClosed(gen, gotFrame)` bilgisini kendisi taşır; kare almış bağlantı boş sayılmaz. Tick tabanlı çıkarım kaldırıldı.
  - Testler: ertelenmiş resume, iptal, hız sınırı; kare-sonra-kapanış (4 sn basamaktan 500 ms'ye), bayat ilk-kare olayı.
- **Review turu 2:**
  - P1: resume hakkı bitmişken (manual öncesi) ya da soğuma sürerken atlanan her akan bağlantı `pendingResumeConn` olur; `tick()` manual + soğuma bitince `RESTART_CODEC` döndürür (manual olmadan beklemeye devam eder, hata/kayıp/Detached temizler). Test: 3 kısmi bağlantı, +10 sn'de kararlı bağlantı, +15 sn manual sonrası resume.
  - P2: "Yeniden dene" tıklaması `controller.resetVideoBackoff()` çağırır (`MainActivity` yalnız tıklama işleyicisi) -> `Event.ResetVideoBackoff`: boş-kapanış sayacı sıfırlanır, bekleyen video yeniden açma en geç şimdi+500 ms'ye çekilir (daha erkense değişmez). SessionMachine düzeyinde test edildi; `MainActivity` bağlantısının kendisi birim testsiz (tablette: kısmen 4 sn basamaktayken düğmeye basınca ~0,5 sn'de yeniden bağlanmalı).

- **Review turu 3:** `resetVideoBackoff()` artık `events.offer` yerine `EngineMailboxes.videoBackoff` (`Latest`) yuvasına `post` eder (tıklama hiç düşmez, tekrarlar birleşir); `Latest.kt` dosya listesine eklendi. `EngineMailboxesTest`'e yuva testi eklendi.

## Open questions

(yok)
