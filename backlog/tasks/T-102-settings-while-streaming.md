---
id: T-102
title: Taslak — bağlıyken açılabilen ayarlar paneli (akış sürerken, bağlantı paneline dönmeden)
status: done
phase: 4
owner: orchestrator
depends_on: [T-096, T-101]
decisions: []
files:
  - backlog/tasks/
  - docs/decisions/
---

## Amaç

Kullanıcı isteği (2026-10-01): ayarlara yalnızca ilk bağlanma panelinden değil, bağlıyken de ulaşılabilsin. Bugün bağlantı paneli akış başlayınca gizleniyor; transport, ses ve görüntü modu gibi seçimler akış sırasında değiştirilemiyor.

## Konuşulacaklar (yeni oturumda kullanıcıyla)

1. **Açma yolu** (biri ya da birkaçı):
   - (a) klavye kısayolu, örn. Ctrl+Shift+S (mevcut Ctrl+Shift+Esc/8/9/0 kalıbı);
   - (b) dokunmatik hareket, örn. üç/dört parmakla uzun bas (HarmonyOS kenar hareketleriyle çakışmamalı);
   - (c) ekran köşesinde gizli, dokununca beliren küçük düğme;
   - (d) Mac menü çubuğu uygulamasından (host tarafı ayarlar).
2. **Görünüm:** akış arkada sürerken yarı saydam yan panel ya da alt sayfa. Panel açıkken girdi Mac'e gitmez; kapanınca devam eder. Girdi takılı kalmamalı: panel açılırken release-all.
3. **İçerik:**
   - bağlantı: Otomatik/USB/Wi-Fi, bağlantıyı kes;
   - görüntü modu: Netlik/Akıcı/Performans;
   - ses: aç/kapa, çıkış (Düşük gecikme/Uyumlu);
   - işaretçi/touchpad hızı, Ctrl↔Cmd eşlemesi (karar 0008), kalem ayarları;
   - istatistik katmanı.
   - Hangi ayarlar anında, hangileri yeniden yapılandırmayla uygulanır?
4. **Host tarafı ayarlar** (PLAN Aşama 4): çözünürlük/ölçek, bit hızı, codec — tabletten mi, Mac menüsünden mi?
5. Mod seçimi (ikinci ekran / ana ekran / yansıtma) bu panele mi girsin?

## Kararlar (2026-10-01, kullanıcı)

- Açma: klavye kısayolu (Ctrl+Shift+6) ve Mac menü çubuğu.
- Görünüm: sağ yan panel.
- Host ayarları (bit hızı) tabletteki panelden.
- Mod seçimi sonra, ayrı kartta.

Ayrıntılar karar 0013'te.

## Plan

Bölündü:
- T-104: protokol kod çözücüleri;
- T-105: tablet yan paneli;
- T-106: host bit hızı ve menü.
