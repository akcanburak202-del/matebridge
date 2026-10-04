---
id: T-229
title: Client — T-227 rediscovery edge cases with more than one paired Mac (candidate starvation, user pick inherits identity gate)
status: todo
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

_(Ajan kodlamadan önce doldurur.)_

## Handoff

_(Ajan bitirince doldurur.)_
