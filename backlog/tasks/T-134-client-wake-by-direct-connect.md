---
id: T-134
title: Tablet — Mac'i saklanan IP'ye doğrudan TCP bağlanarak uyandır (magic packet işe yaramıyor)
status: todo
phase: 4
owner: android-client-dev
depends_on: [T-133]
decisions: []
files:
  - client-android/app/src/
  - backlog/tasks/T-134-client-wake-by-direct-connect.md
---

## Amaç

Cihaz ölçümü (NOTES 2026-10-02 ~15:05–15:21): magic packet (174 paket, yayın + unicast :9) uyuyan Mac'i **uyandırmadı**. ICMP ping de uyandırmıyor (Wi-Fi çipi uykuda kendisi cevaplıyor). **Host'un dinleyen kontrol portuna (47001) TCP bağlantısı Mac'i 1 s içinde karanlık uyanmaya soktu ve bağlantı 435 ms'de kuruldu.** Karanlık uyanmada oturum kurulunca host (T-128 `session_started`) Mac'i tam uyandırıyor (14:44 testinde doğrulandı).

Mac uyurken Bonjour keşfi Mac'i bulamaz (uyku vekili yok), bu yüzden şu an uyandırma bölümünde tablet hiç TCP bağlantısı denemiyor.

## Kabul kriterleri

- [ ] `WolStore` saklanan host IPv4'ün yanında kontrol **portunu** da saklar (TXT'nin geldiği çözümlemeden; yoksa 47001).
- [ ] **Uyandırma bölümünde doğrudan bağlantı:** T-129 uyandırma bölümü başladığında (otomatik — ev ağında — ya da elle "Mac'i uyandır"/"Bağlan"), magic packet'lere ek olarak saklanan IP:port'a **normal oturum bağlantısı** (HELLO akışı, mevcut `SessionMachine` yolu) denenir: Wi-Fi ağına bağlı soketle, bağlantı zaman aşımı ~3 s, denemeler arası ~2 s, bölüm süresince (20 s). Bağlantı kurulursa normal oturum akışı (HELLO_ACK, şifreleme) devam eder ve bölüm `connected` ile biter. Keşif (NSD) paralel çalışmaya devam eder; hangisi önce bulursa o kullanılır, ikinci bağlantı açılmaz.
- [ ] Bu doğrudan deneme yalnızca uyandırma bölümü içinde yapılır; "Mac uyku modunda" (BYE HOST_SLEEP) durumunda, kullanıcı eylemi/ön plana dönüş olmadan **hiç** paket gönderilmez (T-133 kuralı aynen).
- [ ] Taşıma modu: Wi-Fi ve Otomatik modda (USB yoksa ya da USB kaybolduysa) çalışır. Otomatik modda Mac uyanıp USB tüneli geri gelirse mevcut auto/migrate mantığı USB'ye geçebilir (değişmez).
- [ ] "Mac uyku modunda" durumunda "Bağlan" düğmesi de aynı yolu başlatır (uyandırma bölümü + doğrudan bağlantı); kullanıcının modu değiştirmesine gerek kalmaz.
- [ ] Log: `MB/session ev=wake_connect attempt=N result=ok|timeout|refused|error ms=…` (adres yok). Bölüm başı/sonu T-129 logları aynen.
- [ ] Saf mantık testli (bölüm içinde doğrudan deneme zamanlaması, keşifle yarış — tek bağlantı, host_sleep'te sessizlik). `./scripts/check.sh` geçiyor.

## Kapsam dışı

Host değişikliği yok. Cihaz testi (orkestratör).

## Plan

(ajan doldurur)

## Handoff

(ajan doldurur)
