---
id: T-133
title: Tablet — BYE(HOST_SLEEP) sonrası "Mac uyku modunda" (otomatik yeniden bağlanma yok); USB'de de `wol` öğren
status: in_progress
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

1. **Protokol:** `Bye.HOST_SLEEP = 6` (`Messages.kt`); `FixtureTest.valid`'e `bye_host_sleep` → `Bye(Bye.HOST_SLEEP)`.
2. **`SessionMachine`:** `Bye(HOST_SLEEP)` → iki bağlantı kapanır (graceful değil, BYE geri gönderilmez), faz `FAILED`, `Ui(Failed(HOST_SLEEP))` — yeniden deneme zamanlayıcısı yok (REJECTED BYE ile aynı yol). Yeni `SessionUi.Cause.HOST_SLEEP`. Girdi tarafı mevcut kapanış yolunu kullanır (panel görünür → release-all).
3. **Saf mantık `session/HostSleep.kt`** (JVM testli):
   - `HostSleepGate`: `asleep`; `onUi(state)` `Failed(HOST_SLEEP)` gelince uykuya girer (giriş anında true); `clear(reason)` (`foreground|connect|wake`) uyku durumunu temizler ve önceki değeri döner. Uykudayken otomatik bağlanma / keşif / AUTO USB denemesi / otomatik uyandırma yapılmaz.
   - `WolRefresh`: USB'de tek seferlik TXT `wol` yenilemesi. `onSession(connectedOnUsb, now, wifi)` → `Start` (bir kez; Wi-Fi yoksa `Finish(no_wifi)`), `onTxt(wol)` geçerli adres gelince `Finish(stored)`, `tick(now)` 10 s sonunda `Finish(none)`, `cancel()` (arka plan / uyku) → `Finish(cancelled)`. `reset()` her `onStart`'ta.
4. **`WakePlanner.update`:** yeni `hostAsleep` parametresi: uykudayken bölüm başlamaz, çalışan bölüm `Stop(host_sleep)`.
5. **`MainActivity`:** `render()` içinde uyku girişi → keşif ve USB TXT yenilemesi durur, `pickGen++`; `onDiscovered`, `autoStep`, `wolStep` uykuda bekler. `onStart` → `clear(foreground)` (normal akış, T-129 otomatik uyandırma dahil). "Bağlan" (adres boşken) ve "Mac'i uyandır" uykudayken `clear` + `applyTransport()` (+ elle uyandırma). USB TXT yenilemesi: oturum `Connected` ve uç nokta USB iken ayrı, `onFound`'u yok sayan bir `MacDiscovery` (yalnız `onTxt`), 10 s; `ev=wol_refresh result=stored|none|no_wifi` (arka plan/uyku iptali `cancelled`).
6. **Metin:** `strings.xml` `state_host_sleep` ("Mac uyku modunda…"), `cause_host_sleep`.

## Handoff

(ajan doldurur)
