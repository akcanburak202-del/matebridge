---
id: T-229
title: Client — T-227 rediscovery edge cases with more than one paired Mac (candidate starvation, user pick inherits identity gate)
status: done
phase: 6
owner: android-client-dev
depends_on: [T-227]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/EndpointRediscovery.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/session/
  - backlog/tasks/T-229-client-rediscovery-multi-mac.md
---

## Amaç

T-227'nin dördüncü Codex turu (`~/.cache/matebridge-tools/data/codex-T-227d.txt`) iki P2 buldu. İkisi de erişilebilirlik sorunu (veri sızıntısı değil) ve yalnız birden fazla eşleşmiş Mac varken ortaya çıkıyor. Kullanıcının tek Mac'i var: düşük öncelik.

1. **Aday açlığı:** keşif sonucu, bağlanmakta olan adayın yerini alabiliyor (`EndpointRediscovery.kt` ~225). Doğru Mac A önce, portu kapalı Mac B sonra çözülürse B A'yı ezer, zaman aşımına uğrar, geri dönülür; her yeniden başlatmada tekrarlar. Çare: mevcut aday denemesi bitsin, sonraki sonuçlar sınırlı bir kuyrukta beklesin; `unreachable` adaylar bölümde geri planda kalsın.
2. **Kullanıcı seçimi eski kimliği miras alıyor:** `onUserStart()` bölümü bitiriyor ama `known` (son doğrulanmış host) kalıyor (~245). Kullanıcı B'ye "Bağlan" der, B'nin ilk denemeleri düşerse yeni bölüm A'yı bekler; `CONNECT_BUTTON` `userInitiated=false` olduğu için `ExpectHost` uygulanır, B `WRONG_HOST` ile reddedilir. Çare: kullanıcı farklı bir uç nokta seçince `known` temizlensin ya da o hosta yeniden bağlansın.

## Kabul kriterleri

- [ ] [JVM] İki senaryo için birer test (Codex'in dizisi).
- [ ] [JVM] T-227 testleri değişmeden geçer.

## Plan

1. **Aday açlığı (`EndpointRediscovery`)**:
   - Bir aday denenirken (`candidate != null`) gelen yeni keşif sonucu adayın yerini almaz. Sonuç sınırlı bir kuyruğa (`MAX_QUEUE = 4`, tekrarsız, `foreign` hariç) girer ve `onDiscovered` yeni `Pick.QUEUED` döner (bağlanma yok).
   - Bölümde `Unreachable` olan adaylar `unreachable` kümesine girer (geri plan). Kuyruktan çekerken önce hiç denenmemiş adresler gelir. Kuyruk doluysa yeni (taze) bir sonuç `unreachable` bir girdiyi çıkarır, yoksa düşer.
   - Tek istisna: o an denenen aday zaten `unreachable` işaretliyse, taze bir adres onun yerini alır (`CONNECT`). Böylece portu kapalı Mac B her yeniden başlatmada önce çözülse bile doğru Mac A'yı bekletmez.
   - `nextQueued(allowed)`: `Foreign`/`Unreachable` kararından sonra kuyruktaki sıradaki uygun adresi aday yapar (yoksa null). Kuyruk ve küme bölüm bitince (`endEpisode`) temizlenir.
2. **Kullanıcı seçimi (`onUserStart(ep)`)**: bölümü bitirir. `ep` son doğrulanmış hostun adresinden (`knownEp`) farklıysa `known`/`knownEp` da temizlenir. Böylece sonraki bölümde `expectedHost()` null olur ve kullanıcının seçtiği Mac `WRONG_HOST` ile reddedilmez. B bağlanınca kimliği olağan yoldan öğrenilir. Argümansız çağrı eski davranışı korur.
3. **MainActivity (yalnız yeniden keşif kodu)**:
   - `connect()`: `rediscovery.onUserStart(ep)`.
   - `onDiscovered()`: `Pick.QUEUED` → `pairPick.onDiscovered` sonrası dön (bağlanma yok).
   - `onRediscoveryVerdict()` içindeki ertelenmiş blok: eski adrese dönmeden önce `rediscovery.nextQueued { pairPick.allowsAuto(it) }`. Varsa `endpoint_rediscover_found` (mevcut alanlar) loglanır ve ona bağlanılır, yoksa eski adrese dönülür.
   - Yeni log olayı yok (`docs/LOGGING.md` `files:` dışında).
4. **JVM testleri** (`EndpointRediscoveryMultiMacTest.kt`, yeni dosya; T-227 testleri değişmez):
   - A önce, B sonra → B kuyrukta, A kabul.
   - B önce → A kuyrukta, B ulaşılamaz → A çekilir ve kabul.
   - Sonraki yeniden başlatmada `unreachable` B denenirken taze A onun yerini alır.
   - Kuyruk sınırı ve önceliği.
   - Kullanıcı B'ye "Bağlan" der, B düşer → yeni bölümde `expectedHost()` null, B `Connected(macB)` → `None` ve kimlik B olur.
   - Aynı adrese kullanıcı başlangıcı kimliği korur.

## Handoff

- **Commit:** `74efb6c` plan, `3291301` uygulama ve testler, `c45bb81` Codex inceleme düzeltmesi (P2). Dal: `task/T-229-rediscovery-multi-mac`.
- **Dokunulan dosyalar:**
  - `client-android/app/src/main/kotlin/dev/matebridge/client/session/EndpointRediscovery.kt`:
    - `Pick.QUEUED`, sınırlı kuyruk (`MAX_QUEUE = 4`), `unreachable` kümesi,
    - `nextQueued(allowed)`,
    - `onUserStart(ep)`.
  - `client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt` (yalnız yeniden keşif satırları):
    - `onDiscovered()` `QUEUED`'da bağlanmaz,
    - `onRediscoveryVerdict()` eski adrese dönmeden önce kuyruğu dener,
    - `connect()` → `onUserStart(ep)`.
  - `client-android/app/src/test/kotlin/dev/matebridge/client/session/EndpointRediscoveryMultiMacTest.kt` (yeni, 10 test).
- **İnceleme düzeltmesi (Codex T-229 P2):**
  - Sorun: `onUserStart(B)` ile B'nin `Connecting`'i arasında eski oturumun geç `Connected(hostTag=A)` durumu render edilirse `learn(A, B)` çağrılıyordu.
  - Çözüm: `onUserStart(ep)` bir bariyer kurar (`userStartEp`). O başlangıcın `Connecting(ep)` ya da kendi `Failed(endpoint=ep)` durumu (kilit) görülene kadar gelen her durum eski oturumun geç durumu sayılır ve hiçbir şeye karar vermez: kimlik öğrenmez, düşüş saymaz. Bu, T-227'nin aday için kullandığı `candidateStarted` mantığının aynısı.
  - `SessionUi`'ye uç nokta damgası eklenmedi: `SessionUi.kt`/`SessionMachine.kt` kart `files:` dışında.
  - Oturum başka bir adrese geçerse bariyer yeni adresi bekler; `reset()` bariyeri temizler.
  - Testler: `aLateConnectedOfTheSupersededSessionIsNotLearntForTheUserPick` (Codex'in sırası), `aUserStartEndedByItsOwnFailureReleasesTheBarrier`.
- **Kabul kriterleri:**
  - [x] [JVM] İki Codex dizisi:
    - `aLaterResultWaitsWhileTheRightHostIsTried`, `anUnreachableCandidateHandsOverToTheQueuedOneNotToTheOldAddress`, `aFreshAddressReplacesACandidateThatWasAlreadyUnreachable`;
    - `aUserPickedOtherMacIsNotRefusedByALaterEpisode`.
  - [x] [JVM] `EndpointRediscoveryTest` (31) ve `WrongHostGateTest` dosyalarına dokunulmadı; hepsi geçti.
  - `./scripts/check.sh` `c45bb81` üzerinde: ALL OK.
- **Varsayımlar:**
  - Kuyruk bölüme ait; `Accepted`/sıfırlama/kullanıcı başlangıcıyla temizlenir. Kuyruk dolarsa taze bir sonuç `unreachable` bir girdiyi çıkarır, yoksa yeni sonuç düşer. Yeniden başlatma onu zaten tekrar bildirir.
  - Taze adresin, o an bağlanmakta olan ve bu bölümde zaten `unreachable` işaretli bir adayın yerini alması bilinçli bir istisna. Bu, T-227'nin eski "yerini alma" davranışının (geç durum koruması dahil) daraltılmış hali.
  - `onUserStart(ep)`: `ep` son doğrulanmış hostun adresinden farklıysa kimlik unutulur. Aynı adrese kullanıcı başlangıcı kimliği korur. Seçilen host bağlanınca kimliği olağan yoldan öğrenilir.
  - Yeni log olayı eklenmedi (`docs/LOGGING.md` `files:` dışında). Kuyruktan çekilen aday mevcut `endpoint_rediscover_found old= new=` satırıyla loglanır; kuyruğa alma loglanmaz.
- **Test edilmeyenler:** Cihazda hiçbir şey denenmedi. Kullanıcının tek Mac'i var, bu yüzden çok-Mac senaryoları cihazda büyük olasılıkla denenemez. Tablette yalnız regresyon kontrolü:
  1. T-227 cihaz denemesi (Wi-Fi modunda Mac Wi-Fi → Ethernet, Mac Wi-Fi kapalı) aynen geçmeli. ≤ ~10 sn içinde `endpoint_rediscover` → `endpoint_rediscover_found old=*.107 new=*.106` → `endpoint_rediscover_result result=accepted` gelmeli; `wrong_host` olmamalı.
  2. "Bağlan" (adres yazmadan) Mac'e normal bağlanmalı. Sonra Mac'in ağını kısa süre kesip geri verince yeniden bağlanmalı ve `wrong_host` olmamalı.
  3. Mac kapalıyken `endpoint_rediscover restart=` satırları 8/16/30 sn aralıkla sürmeli; bağlıyken ve USB'de bu satır çıkmamalı.
- **Açık sorular:**
  1. (Not) Kuyruk olayları için ayrı bir log satırı istenirse (`endpoint_rediscover_queued`) `docs/LOGGING.md` kart kapsamına eklenmeli.
