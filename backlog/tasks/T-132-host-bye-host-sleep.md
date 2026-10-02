---
id: T-132
title: Mac — uykuya girerken oturumu BYE(HOST_SLEEP) ile kapat
status: in_progress
phase: 4
owner: mac-host-dev
depends_on: [T-128]
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/
  - host-mac/Sources/MateBridgeCore/
  - host-mac/Tests/
  - backlog/tasks/T-132-host-bye-host-sleep.md
---

## Amaç

Cihaz testi (NOTES 2026-10-02 ~14:45): T-128 ile `pmset sleepnow` artık gerçekten uyutuyor (`wake_display_suppressed`, pmset "Entering Sleep"). Ama oturum **açık kaldı**: TCP bağlantıları uykuda yaşadı, tabletin 500 ms PING'leri ve 0,5 s'de bir video yeniden bağlanma denemeleri Mac'i sürekli **DarkWake**'e soktu (`E_RX_IP_PACKET`, 14:42:19 / 14:43:07 / 14:43:55, her biri 45 s). Tablet oturumu canlı sandı → son karede donmuş görüntü, "Mac uyandırılıyor…" hiç görünmedi, kullanıcı uygulamadan çıkıp girmek zorunda kaldı.

Çözüm (PROTOCOL.md §4 `BYE` reason `6` HOST_SLEEP, fixture `bye_host_sleep`): host uykuya girerken oturumu kendisi kapatır.

## Kabul kriterleri

- [ ] Protokol: `BYE` reason `6` HOST_SLEEP Swift tarafında tanımlı; `FixtureTests`'e `bye_host_sleep` eklenir (kodlama/çözme bayt bayt).
- [ ] Sistem uykusu bildiriminde (`kIOMessageSystemWillSleep`; `CanSystemSleep` değil — uyku iptal edilebilir) aktif ya da kanıt bekleyen oturum varsa: release-all (mevcut BYE yolu), `BYE(HOST_SLEEP)` gönderilir, iki bağlantı kapatılır, ses durdurulur; bunlar `IOAllowPowerChange`'den **önce** ve sınırlı sürede (ör. en çok ~300 ms beklenir; gönderim bitmese de onay verilir — uyku geciktirilmez/engellenmez). PAIRING onayı bekleyen bağlantılar da kapatılır.
- [ ] Sanal ekran: uykuda display grace beklemeden kaldırılabilir ya da mevcut grace ile bırakılır — hangisi daha güvenliyse seç ve Handoff'ta gerekçelendir (ekran uykuda oluşturulamıyor: T-040 notu).
- [ ] Uyanınca (`did_wake` ya da yeni oturum) normal akış: tablet yeniden bağlanınca T-128'in `session_started` yolu ekranı tam uyandırır. Uyku sırasında gelen bağlantılar (karanlık uyanma) normal kabul edilir.
- [ ] Log: `component=session ev=bye_sent reason=host_sleep` ve `ev=power` sıralaması görülebilir.
- [ ] Saf mantık (ne zaman BYE gönderilir) testli. `./scripts/check.sh` geçiyor — **not:** Android tarafı `bye_host_sleep` fixture testi T-133 birleşene kadar kırmızı olabilir; yalnızca o test kırmızıysa kabul.

## Kapsam dışı

Cihaz testi (orkestratör). Host'u çalıştırma.

## Plan

1. **Core (saf):**
   - `ByeReason.hostSleep = 6` (`Messages.swift`); `FixtureTests` geçerli fixture listesine `bye_host_sleep` → `.bye(.hostSleep)`.
   - `ReleaseCause.hostSleep` (log adı `host_sleep`); test yardımcısı `allReleaseCauses`'a eklenir.
   - `SessionMachine.hostSleep()`: `shutdown()` ile aynı yol (`endAll`), ama `BYE(HOST_SLEEP)`, neden `.hostSleep`, bağlantı başına `ev=bye_sent reason=host_sleep`. Aktif oturum: release-all → BYE → kapat → video kapat → `sessionEnded`. Kanıt bekleyen / HELLO bekleyen / anahtar arayan bağlantılar: BYE + kapat. PAIRING onayı bekleyen: onay iptal + BYE + kapat. Açık kalmış (orphan) onay penceresi de kapanır; kanıtlanmamış video bağlantıları kapanır.
   - `Session/HostSleep.swift`: `HostSleep.endsSessions(_:)` (yalnızca `.willSleep`; `can_sleep` iptal edilebilir), `budgetUs = 300 ms`, `lingerUs(startUs:nowUs:)` (kalan bütçe − pay, alt sınır 0), `waitDeadlineUs`.
2. **Host (`SessionServer`):** kendi `SystemPowerObserver`'ı (ikinci `IORegisterForSystemPower` kaydı; `StreamCoordinator`'ınkine ve `main.swift`'e dokunmadan). İşleyici güç kuyruğunda, `IOAllowPowerChange`'den önce: `willSleep` → oturum kuyruğuna `hostSleep()` işi (bsd kapanış bekleme süresi kalan bütçeye kısaltılır), sonra semafor + `flushGroup` toplamda en çok 300 ms beklenir; bitmese de döner (uyku onaylanır). Log `component=session ev=host_sleep conns=… ` ve `ev=host_sleep_ack waited_ms=… flushed=…`. `start()` gözlemciyi kurar, `stop()` kapatır.
3. **Sanal ekran:** mevcut grace ile bırakılır (gerekçe Handoff'ta).
4. **Testler:** `SessionMachineTests` (hostSleep: aktif, kanıt bekleyen, PAIRING bekleyen, orphan, boş) + `HostSleepTests` (olay seçimi, bütçe hesabı) + fixture.

## Handoff

(ajan doldurur)
