---
id: T-128
title: Mac — kasıtlı uykuya saygı, oturumda ekran uykusunu önle, Bonjour TXT `wol` (Wake-on-LAN adresleri)
status: todo
phase: 4
owner: mac-host-dev
depends_on: [T-081]
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/
  - host-mac/Sources/MateBridgeCore/
  - host-mac/Tests/
  - backlog/tasks/T-128-host-sleep-policy-wol-txt.md
---

## Amaç

Ölçüm (NOTES 2026-10-02 ~13:45): tablet oturumu açıkken `pmset sleepnow` → ekran kapandı → SCStream -3815 → T-081 `wake_display` (`IOPMAssertionDeclareUserActivity`) → **sistem uykusu iptal oldu** (pmset log'da Sleep girdisi yok), Mac kilitlendi, görüntü 1,2 s'de geri geldi. Yani MateBridge kasıtlı uykuyu engelliyor.

**Kullanıcı kararı (2026-10-02):** Mac uzun süre kullanılmayınca uyusun (enerji tasarrufu; dakika ayarını kullanıcı macOS'ta kendisi yapar). Akış: tablet kendi ekran zaman aşımıyla kapanır → oturum BYE ile biter → Mac boşta → macOS ayarına göre ekran uykusu + sistem uykusu → kullanıcı dönünce tablet Wake-on-LAN magic packet ile Mac'i uyandırır (T-129) → otomatik yeniden bağlanma → kilit ekranında şifre tablet klavyesiyle.

Bu kart host tarafı. Protokol: `docs/PROTOCOL.md` §3 madde 1, TXT `wol` (orkestratör yazdı; bu kart yalnızca uygular).

## Kabul kriterleri

- [ ] **Kasıtlı / sistem uykusu engellenmez.** Sistem uykuya giderken (IOKit `IORegisterForSystemPower`: `kIOMessageCanSystemSleep` / `kIOMessageSystemWillSleep`; ve/veya `NSWorkspace.willSleepNotification`) T-081 uyandırması **bastırılır**; `kIOMessageSystemHasPoweredOn` / `didWakeNotification` ile yeniden açılır. Sıralama sorunu: `pmset sleepnow`'da ekran kapanması / -3815 uyku bildiriminden **önce** gelebilir. Bu yüzden `capture_source_lost` uyandırması kısa bir süre (ör. ~1,5 s, sabit olarak tanımla) ertelenir; bu pencerede uyku bildirimi gelirse uyandırma yapılmaz. `display_create_nil` yeniden denemeleri de uyku süresince uyandırma yapmaz. `kIOMessageCanSystemSleep`'e `IOAllowPowerChange` ile hemen izin verilir (uykuyu geciktirme yok).
- [ ] Log: `component=net ev=power state=will_sleep|did_wake|can_sleep` (değişimde) ve uyandırma bastırılınca `ev=wake_display_suppressed reason=system_sleep` (bölüm başına bir kez). Cihaz testinde sıralamayı görebilmek için zamanlar host saatinde.
- [ ] **Oturum açıkken boşta ekran uykusu yok.** Kabul edilmiş (PAIRED) oturum boyunca `IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep)` tutulur, oturum bitince (BYE, devralma, kopma, kapanış) bırakılır. Gerekçe: kullanıcı ekran uykusunu açınca oturum ortasında ekran kararıp kilit ekranı çıkmasın; boşta kalma süresini tablettin kendi ekran zaman aşımı yönetir. (T-081'deki "PreventUserIdleDisplaySleep eklenmez" maddesinin yerine geçer — kullanıcı kararı.) Display grace süresinde (oturum yok) assertion yok. Mevcut `.userInitiated` activity (sistem boşta uykusunu önler) davranışı oturumla sınırlı kalır; oturum bitince bırakıldığını doğrula (bırakılmıyorsa düzelt).
- [ ] **TXT `wol`.** `BonjourAdvertiser` TXT'ye `wol=` ekler (PROTOCOL.md formatı: küçük harf `aa:bb:cc:dd:ee:ff`, virgülle, en çok 4; `en*`, `IFF_UP`, IPv4 adresi olan arayüzler; `getifaddrs` AF_LINK). Uygun arayüz yoksa anahtar hiç yazılmaz. Ağ arayüzleri değişince (ör. `SCDynamicStore` ya da `NWPathMonitor` değişimi) TXT yeniden yayınlanır; değer aynıysa tekrar yayın yok. Log: `component=session ev=bonjour_txt wol_count=N` (değişimde; MAC adresleri loglanmaz).
- [ ] Saf mantık testli: uyku/uyandırma politika durum makinesi (erteleme penceresi, bastırma, uyanınca yeniden açılma), TXT `wol` değer üretimi (biçim, sıralama kararlı, 4 sınırı, filtre). IOKit / dns_sd / getifaddrs çağrıları ince sarmalayıcılarda.
- [ ] `./scripts/check.sh` geçiyor.

## Kapsam dışı

- Gerçek `pmset sleepnow` / ekran uykusu cihaz testi (orkestratör kullanıcıyla yapar; Mac uyuyunca ajan devam edemez). Host'u çalıştırma, bundle etme.
- macOS enerji ayarlarını değiştirme.

## Plan

(ajan doldurur)

## Handoff

(ajan doldurur)
