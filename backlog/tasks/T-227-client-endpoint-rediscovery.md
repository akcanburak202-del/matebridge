---
id: T-227
title: Client — when the stored Mac address stops answering, rediscover the host via Bonjour (Mac moved from Wi-Fi to Ethernet)
status: todo
phase: 6
owner: android-client-dev
depends_on: []
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/
  - client-android/app/src/test/kotlin/dev/matebridge/client/session/
  - docs/LOGGING.md
  - backlog/tasks/T-227-client-endpoint-rediscovery.md
---

## Amaç

Cihaz 2026-10-04 ~22:15 (T-127 topoloji 2): Mac Wi-Fi'den (192.168.1.107) Ethernet'e (192.168.1.106) geçince ve Mac Wi-Fi'si kapatılınca tablet Wi-Fi modunda Mac'i yeniden bulamadı; host Bonjour'da Ethernet arayüzünden (`dns-sd -B _matebridge._tcp` → if 7) görünüyordu. Kullanıcı uygulamayı kapatıp açınca hemen bağlandı. Yani açılıştaki keşif doğru adresi buluyor, ama çalışırken kayıtlı adrese yeniden bağlanma döngüsü yeni adresi aramıyor. Mac'in adresi değişince (Ethernet takma, DHCP yenileme, Mac yeniden başlama) uygulamayı yeniden açmak gerekmemeli.

## Bağlam

- Ajan önce mevcut akışı okur: kayıtlı uç nokta / `connect_start host=` / NSD keşfi / yeniden bağlanma ve geri çekilme (session paketi), T-096 otomatik taşıma, T-128..T-134 uyanma (kayıtlı IP'ye doğrudan TCP), `migrate_request`.
- İstenen davranış: Wi-Fi modunda kayıtlı adrese art arda N deneme (ör. 2–3, ya da ~5 sn) başarısız olursa NSD keşfini yeniden başlat; aynı `device`/host kimliğine ait yeni bir adres bulunursa ona bağlan ve kaydı güncelle. Eşleştirme kimliği (anahtar kanıtı) zaten bağlanınca doğrulanır; yeni adres kimliği değiştirmez. Bulunamazsa mevcut geri çekilme sürer.
- Uyku/uyanma yolu (kayıtlı IP'ye doğrudan TCP ile Mac'i uyandırma) bozulmamalı: uyuyan Mac Bonjour'da görünmeyebilir; yeniden keşif kayıtlı adres denemelerinin yerine değil, yanına gelir.
- Log: `ev=endpoint_rediscover reason=… old=<redacted?> new=…` — adresleri loglama kuralı için docs/LOGGING.md ve NOTES 2026-10-04 `migrate_request` IP notuna bakın; gerekirse adresin yalnız son okteti.

## Kabul kriterleri

- [ ] [JVM] Kayıtlı adres N kez başarısız → keşif başlar; keşif aynı host için yeni adres verince ona bağlanılır ve kayıt güncellenir.
- [ ] [JVM] Keşif sonuç vermezse kayıtlı adresle geri çekilme aynen sürer; uyandırma yolu değişmez.
- [ ] [JVM] Başka bir host (farklı kimlik) yeni adres olarak kabul edilmez.
- [ ] [device] Mac Wi-Fi → Ethernet geçişinde (Mac Wi-Fi kapatılarak) tablet uygulama yeniden açılmadan ≤ ~10 sn içinde yeniden bağlanır.

## Plan

_(Ajan kodlamadan önce doldurur.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulananlar:**
- **Açık sorular:**
