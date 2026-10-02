---
id: T-133
title: Tablet — BYE(HOST_SLEEP) sonrası "Mac uyku modunda" (otomatik yeniden bağlanma yok); USB'de de `wol` öğren
status: review
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

- [x] Protokol: `Bye.HOST_SLEEP = 6`; `FixtureTest`'e `bye_host_sleep` eklenir.
- [x] `BYE(HOST_SLEEP)` gelince: release-all/kapanış mevcut BYE yoluyla; yeni durum "Mac uyku modunda" (panelde Türkçe metin). Bu durumda **otomatik yeniden bağlanma ve otomatik uyandırma yok** (uyuyan Mac'e giden her paket onu karanlık uyanmaya sokar). "Bağlan" ve "Mac'i uyandır" düğmeleri görünür; basılınca normal akış (uyandırma bölümü + bağlanma).
- [x] Uygulama arka plana gidip yeniden ön plana gelince (tablet ekranı kapatıp açma, uygulamaya dönme) uyku durumu temizlenir ve normal akış başlar: Mac bulunamazsa T-129 otomatik uyandırma (ev ağındaysa).
- [x] **USB'de `wol` öğrenme:** taşıma USB iken (ya da auto→USB) oturum kurulduktan sonra tek seferlik, sınırlı süreli (ör. 10 s) bir Bonjour keşfi/çözümlemesi çalıştırılır; bulunan TXT `wol` mevcut `WolStore` ile saklanır (Wi-Fi alt ağı da). Wi-Fi kapalıysa sessizce atlanır. Bu keşif bağlantı kararlarını **etkilemez** (yalnız TXT için). Log: `ev=wol_refresh result=stored|none|no_wifi`.
- [x] Saf mantık testli (uyku durumu geçişleri: BYE(HOST_SLEEP) → bekle; ön plana dönüş → normal; elle bağlan/uyandır). `./scripts/check.sh` geçiyor — **not:** host tarafı `bye_host_sleep` fixture testi T-132 birleşene kadar kırmızı olabilir; yalnızca o test kırmızıysa kabul.

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

- **Commit:** `4cc0113` (uygulama), inceleme düzeltmesi (bu kartla aynı commit'te, aşağıda), plan `cdf5d01`; dal `task/T-133-client-host-sleep` (56ecb58'den). `./scripts/check.sh`: client-android, problar, fixture/vektör denetimleri OK; **tek kırmızı** host-mac `FixtureTests.everyFixtureFileHasATestCase` (`bye_host_sleep` host'ta henüz kapsanmıyor → T-132). Yeni/değişen testler: `HostSleepGateTest` 3, `WolRefreshTest` 7, `WakePlannerTest` +1 (21), `SessionMachineTest` +1 (35), `FixtureTest` (`bye_host_sleep`).
- **Dosyalar:**
  - `protocol/Messages.kt` (`Bye.HOST_SLEEP = 6`), `test/.../protocol/FixtureTest.kt` (`bye_host_sleep`)
  - `session/SessionUi.kt` (`Cause.HOST_SLEEP`), `session/SessionMachine.kt` (BYE HOST_SLEEP → `Failed(HOST_SLEEP)`, yeniden deneme yok)
  - yeni `session/HostSleep.kt`: `HostSleepGate`, `WolRefresh` (saf); yeni `test/.../session/HostSleepTest.kt`
  - `session/Wol.kt`: `WakePlanner.update(..., hostAsleep)` + `REASON_HOST_SLEEP = "host_sleep"`
  - `MainActivity.kt`: uyku kapısı, USB TXT yenilemesi, metinler; `res/values/strings.xml` (`cause_host_sleep`, `state_host_sleep`, `state_host_sleep_no_wol`)
- **Varsayımlar / kararlar:**
  - BYE(HOST_SLEEP) REJECTED BYE ile aynı yoldan gider: iki bağlantı graceful olmadan kapanır, BYE geri gönderilmez, faz `FAILED` (zamanlayıcı yok, PING yok). Girdi bırakma mevcut yol: panel görünür → `syncInputActive` (değişiklik yok).
  - Uykudayken (`HostSleepGate.asleep`) ayrıca: NSD keşfi durdurulur (mDNS sorgusu da paket sayılır), çalışan USB yoklaması geçersiz kılınır (`pickGen++`), `autoStep`/`onDiscovered` bekler, USB TXT yenilemesi iptal, `WakePlanner` çalışan bölümü `Stop(host_sleep)` ile durdurur ve otomatik bölüm başlatmaz. Log: `ev=host_sleep transport=…`, temizlenince `ev=host_sleep_clear reason=foreground|connect|wake`.
  - Temizleyen eylemler: `onStart` (ekranı açma / uygulamaya dönme), "Bağlan" (adres alanı boşsa `applyTransport()` — "Bağlantıyı kes" sonrası ile aynı; doluysa elle adres), "Mac'i uyandır" (`applyTransport()` + elle bölüm), bağlantı modu seçimi (`reconnectForMode`). Ön plana dönüşte T-129 kuralları olduğu gibi (2 s, yalnız ev ağında).
  - Panel metni: `wol` saklıysa "Mac uyku modunda. Uyandırmak için "Mac'i uyandır"a, Mac uyanıksa "Bağlan"a dokun.", değilse "Mac uyku modunda. Mac uyanınca "Bağlan"a dokun." "Mac'i uyandır" düğmesi T-129'daki gibi yalnız `wol` saklıysa görünür.
  - **USB `wol` öğrenme:** etkinlik başlangıcı başına bir kez, oturum `Connected` ve uç nokta USB olduğunda (AUTO→USB göçü dahil). Wi-Fi yoksa hemen `ev=wol_refresh result=no_wifi`. Varsa `ev=wol_refresh_start duration_ms=10000` + ayrı `MacDiscovery` (`onFound` yok sayılır; bağlantı kararlarını etkilemez); TXT mevcut `onHostTxt` → `WolStore` yolundan saklanır (Wi-Fi alt ağı da). Geçerli `wol` gelince `result=stored` (değer değişmese de), 10 s'de gelmezse `result=none`. Arka plan / uyku iptalinde ek değer `result=cancelled` (kartta yoktu).
- **Codex incelemesi düzeltmesi:** USB yoklaması artık `ProbeGuard` (`session/AutoTransport.kt`) ile korunur: `pickGen` yerine `probeGuard.bump()`; yoklama iş parçacığı `connect()`'ten hemen önce `attach(gen, socket)` ile neslin hâlâ güncel olduğunu denetler (değilse bağlanmaz, sonuç da göndermez); her `bump()` (uyku girişi, arka plan, taşıma değişimi) bağlanmakta olan yoklama soketini kapatır. Böylece kuyrukta bekleyen / gecikmiş bir AUTO yoklaması BYE(HOST_SLEEP) sonrası `adb reverse` üzerinden Mac'e ulaşamaz. Test: `ProbeGuardTest` (5).
- **Bilinen sınırlama (kabul edildi):** aynı ağda birden çok Mac `_matebridge._tcp` yayınlıyorsa USB `wol` yenilemesi bağlı olunan Mac yerine başka bir Mac'in TXT `wol` değerini saklayabilir (çözümlenen ilk geçerli TXT kazanır; host kimliği eşleştirilmiyor).
- **Test edilmedi (tablet gerekli):** gerçek BYE(HOST_SLEEP) alımı ve sonrası trafik yokluğu, USB bağlıyken NSD TXT çözümü, metin/düğme görünümü.
- **Tablette kontrol edilecekler** (T-132 host'u ile):
  1. Wi-Fi'de bağlıyken `pmset sleepnow` → logcat'te `bye_recv reason=6`, `session_failed cause=HOST_SLEEP`, `host_sleep transport=wifi`; panelde "Mac uyku modunda…"; sonra 1–2 dk boyunca **hiç** `reconnect`, `transport_probe`, `discovery_found`, `wol_start` yok; Mac `pmset -g log` içinde karanlık uyanma göstermemeli.
  2. Aynı durumda tablet ekranını kapat-aç → `host_sleep_clear reason=foreground`, Mac bulunamayınca ~2 s sonra `wol_start reason=not_found` (ev ağında), Mac uyanıp bağlanır.
  3. Uyku metni ekrandayken "Mac'i uyandır" → `host_sleep_clear reason=wake`, `wol_start reason=manual`, bağlanma; "Bağlan" → `host_sleep_clear reason=connect` ve normal arama/bağlanma.
  4. USB (adb reverse) ile bağlan, Wi-Fi açık: ~10 s içinde `wol_refresh_start` ve `wol_refresh result=stored` (ilk kez öğreniliyorsa ayrıca `wol_stored macs=N home=1`); video/girdi bu sırada etkilenmemeli. Wi-Fi kapalıyken `wol_refresh result=no_wifi`.
  5. USB'de bağlıyken `pmset sleepnow` → `host_sleep transport=usb`; AUTO modunda USB yoklaması ya da Wi-Fi'ye düşüş (`transport_pick … usb_lost`) olmamalı.

## Açık sorular

- Host `everyFixtureFileHasATestCase` T-132 birleşene kadar kırmızı (beklenen).
