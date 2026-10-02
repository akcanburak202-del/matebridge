---
id: T-133
title: Tablet — BYE(HOST_SLEEP) sonrası "Mac uyku modunda" (otomatik yeniden bağlanma yok); USB'de de `wol` öğren
status: todo
phase: 4
owner: android-client-dev
depends_on: [T-129]
decisions: []
files:
  - client-android/app/src/
  - backlog/tasks/T-133-client-host-sleep-and-usb-wol.md
---

## Amaç

Cihaz testi (NOTES 2026-10-02 ~14:45): Mac uyurken tablet oturumu açık sandı, PING ve video yeniden bağlanma paketleri Mac'i sürekli karanlık uyanmaya soktu. Host artık uykudan önce `BYE(HOST_SLEEP)` gönderecek (T-132; PROTOCOL.md §4 BYE reason `6`, fixture `bye_host_sleep`). Ayrıca: tablet USB ile bağlıyken Bonjour keşfi çalışmadığı için `wol` adresleri hiç öğrenilmiyor (yalnızca Wi-Fi keşfi saklıyor) → USB kullanan biri Mac'i tabletten uyandıramaz.

## Kabul kriterleri

- [ ] Protokol: `Bye.HOST_SLEEP = 6`; `FixtureTest`'e `bye_host_sleep` eklenir.
- [ ] `BYE(HOST_SLEEP)` gelince: release-all/kapanış mevcut BYE yoluyla; yeni durum "Mac uyku modunda" (panelde Türkçe metin). Bu durumda **otomatik yeniden bağlanma ve otomatik uyandırma yok** (uyuyan Mac'e giden her paket onu karanlık uyanmaya sokar). "Bağlan" ve "Mac'i uyandır" düğmeleri görünür; basılınca normal akış (uyandırma bölümü + bağlanma).
- [ ] Uygulama arka plana gidip yeniden ön plana gelince (tablet ekranı kapatıp açma, uygulamaya dönme) uyku durumu temizlenir ve normal akış başlar: Mac bulunamazsa T-129 otomatik uyandırma (ev ağındaysa).
- [ ] **USB'de `wol` öğrenme:** taşıma USB iken (ya da auto→USB) oturum kurulduktan sonra tek seferlik, sınırlı süreli (ör. 10 s) bir Bonjour keşfi/çözümlemesi çalıştırılır; bulunan TXT `wol` mevcut `WolStore` ile saklanır (Wi-Fi alt ağı da). Wi-Fi kapalıysa sessizce atlanır. Bu keşif bağlantı kararlarını **etkilemez** (yalnız TXT için). Log: `ev=wol_refresh result=stored|none|no_wifi`.
- [ ] Saf mantık testli (uyku durumu geçişleri: BYE(HOST_SLEEP) → bekle; ön plana dönüş → normal; elle bağlan/uyandır). `./scripts/check.sh` geçiyor — **not:** host tarafı `bye_host_sleep` fixture testi T-132 birleşene kadar kırmızı olabilir; yalnızca o test kırmızıysa kabul.

## Kapsam dışı

Cihaz testi, APK kurulumu (orkestratör).

## Plan

(ajan doldurur)

## Handoff

(ajan doldurur)
