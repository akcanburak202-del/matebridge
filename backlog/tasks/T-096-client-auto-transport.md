---
id: T-096
title: Tablet — "Otomatik" bağlantı modu (USB varsa USB, yoksa Wi-Fi; akış sırasında kablo takılınca/çekilince geçiş)
status: todo
phase: 4
owner: android-client-dev
depends_on: [T-089]
decisions: []
files:
  - client-android/app/src/main/
  - client-android/app/src/test/
  - backlog/tasks/T-096-client-auto-transport.md
---

## Amaç

Kullanıcı isteği (2026-10-01): USB bağlıyken bile tablet Wi-Fi'de kalıyor. Aktarım (`transport` usb|wifi) yalnızca bağlantı panelinden seçilebiliyor ve panel akış sırasında gizli. Geçiş kolay olmalı.

Mevcut durum:
- Host USB tünellerini (`adb reverse`) kablo takılınca kendisi kuruyor (T-039).
- Host aynı cihazın yeni bağlantısını devralma (takeover) ile kabul ediyor (§3.3).

## Kabul kriterleri

- [ ] Yeni aktarım seçeneği **`auto`**, yeni kurulumlarda ve mevcut kullanıcı için varsayılan. Mevcut `usb`/`wifi` tercihi elle seçilmiş sayılır ve korunur. Panelde üç seçenek: Otomatik / USB / Wi-Fi.
- [ ] `auto` bağlanma sırası:
  - Önce USB (`127.0.0.1` kontrol portu) denenir, kısa zaman aşımıyla (≤500 ms).
  - Bağlanamazsa Wi-Fi (Bonjour/son bilinen adres).
  - Log: `ev=transport_pick mode=auto chosen=usb|wifi reason=…`.
- [ ] `auto` modda Wi-Fi'de akış sürerken USB kullanılabilir olursa tablet oturumu USB'ye taşır:
  - Algılama: USB kablosu/veri bağlantısı ve `127.0.0.1` kontrol portunun açık olması.
  - Önce yeni USB bağlantısıyla devralma, sonra eski Wi-Fi bağlantısı kapanır. Kesinti ≤ ~1–2 s.
  - Yoklama hafif olmalı: kablo durumu yayınına (`ACTION_USB_STATE` / şarj durumu) bağlı ya da en sık 2 s'de bir.
  - Host'ta kimlik doğrulamasız bağlantı yığılmamalı: yoklama yalnızca TCP bağlanabilirliğini dener ve hemen kapatır, ya da gerçek bağlantı denemesine dönüşür. Plan'da hangisi seçildiği açıklanır.
- [ ] `auto` modda USB'de akarken kablo çekilirse bağlantı düşer. Yeniden bağlanma, kullanıcı bir şey yapmadan otomatik olarak Wi-Fi'ye düşer.
- [ ] Girdi güvenliği: geçiş sırasında hiçbir tuş, düğme ya da kalem teması takılı kalmaz. Eski bağlantı kapanırken mevcut release-all/BYE kuralları geçerlidir; yeni oturumda girdi yeniden başlar.
- [ ] Elle `usb` ya da `wifi` seçiliyse bugünkü davranış aynen sürer.
- [ ] `--es transport auto|usb|wifi` deney ek parametresi, kalıcı ayarı ezmeden bir açılış için.
- [ ] Saf mantık (seçim, geçiş karar makinesi, sınırlama) birim testli.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

(ajan doldurur, commit eder, sonra uygular)

## Handoff

