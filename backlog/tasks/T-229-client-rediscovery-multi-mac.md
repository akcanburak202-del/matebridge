---
id: T-229
title: Client — T-227 rediscovery edge cases with more than one paired Mac (candidate starvation, user pick inherits identity gate)
status: in_progress
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

_(Ajan bitirince doldurur.)_
