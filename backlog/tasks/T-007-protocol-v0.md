---
id: T-007
title: Protokol v0 taslağı ve altın örnekler
status: done
phase: 0
owner: orchestrator
depends_on: [T-003, T-004, T-005]
decisions: [0001, 0003]
files:
  - docs/PROTOCOL.md
  - protocol/fixtures/
  - docs/NOTES.md
  - scripts/check.sh
  - docs/decisions/0003-keyboard-physical-keycodes.md
---

## Amaç

Aşama 0 bulgularına dayanarak Mac ve tabletin konuşacağı mesajları dondurmak. Bu kart bitmeden host ve client paralel kodlamaya başlamaz.

## Kabul kriterleri

- [x] Aşama 0 bulguları `docs/NOTES.md`'de özetlendi (kalem alanları ve örnekleme hızı, klavye scan code'ları, trackpad davranışı, sanal ekran sonuçları).
- [x] `docs/PROTOCOL.md`: çerçeveleme, HELLO/yetenekler, video kare başlığı, kalem örneği (toplu + geçmiş örnekler), tuş, işaretçi, kaydırma, dokunma, release-all, heartbeat, istatistik.
- [x] Her mesaj için `protocol/fixtures/*.hex`.
- [x] Codex incelemesi (`--high`) yapıldı, bulgular işlendi.
- [x] Kullanıcıya Aşama 0 raporu sunuldu, Aşama 1'e geçiş onayı alındı.

## Plan

1. Aşama 0 bulgularını NOTES'ta özetle (tablo).
2. `docs/PROTOCOL.md`: iki TCP bağlantısı (kontrol+girdi / video), 5 bayt çerçeve, LE. Oturum akışı, tek oturum, onay. Mesaj başına tablo.
3. `protocol/fixtures/gen.py` referans kodlayıcı + açıklamalı `.hex` fixture'lar. `check.sh` güncelliği denetler.
4. İç inceleyici + Codex (`--high`). Bulgular işlenir, Codex tekrar çalıştırılır.
5. Kullanıcıya Aşama 0 raporu, Aşama 1 onayı.

(Plan uygulama sonrası yazıldı. Codex'in hatırlatması üzerine kayda geçirildi.)

## Handoff

- **Commit'ler:** `task/T-007-protocol-v0` dalı (7ae1037 taslak → 10084a8 iç inceleme + Codex 1 → HEAD~1 Codex 2 → HEAD Codex 3).
- **Dokunulan dosyalar:** `docs/PROTOCOL.md`, `protocol/fixtures/` (gen.py, README, 31 `.hex`), `docs/NOTES.md` (Aşama 0 özeti), `docs/decisions/0003-…` (tuş tekrarı ve Cmd tuşu ekleri), `scripts/check.sh` (fixture güncellik denetimi).
- **İncelemeler:** İç inceleyici (16 bulgu) + Codex `--high` üç tur. Codex 1: hover fixture'ı `CONTACT` bitiyle kodlanmıştı (düzeltildi, üreteç artık bayrak değişmezlerini denetliyor), gönderim kuyruğu sınırı, video bağlantısında hata yolu. Codex 2: dokunma bırakışı, çoklu kaynak düğme durumu, release sonrası ilk vuruş. Codex 3: kalem önceliği, istemci sıralaması, geç vuruş (kabul edilen davranış olarak belgelendi).
- **Test edilmeyenler:** Swift veya Kotlin codec'i henüz yok. Bayt uyumu ancak Aşama 1'de iki tarafın fixture testleriyle doğrulanacak. Eğim dönüşüm formülü, CGEvent tuş tekrarı ve Caps Lock kilit ayarı cihazda doğrulanmadı.
- **Açık sorular:** Girdi hakemliği kuralları (kilit, kaynak sahipliği, watchdog) `MateBridgeCore`'da birim testleriyle kapsanmalı. Codex yeni turlarda nadir kenar durumları bulmaya devam edebilir; bunlar uygulama testleriyle ele alınacak.

Kullanıcı 2026-09-29'da Aşama 0 raporunu onayladı, Aşama 1'e geçiş onayı verildi.
