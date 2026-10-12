---
id: T-344
title: Host — CURSOR_STATE `rel_ack_count` (işlenen POINTER_REL sayısı)
status: todo
phase: 7
owner: mac-host-dev
depends_on: []
decisions: [0036, 0025]
files:
  - host-mac/Sources/
  - host-mac/Tests/
  - backlog/tasks/T-344-host-cursor-rel-ack.md
---

## Amaç

Karar 0036 v3 eki; PROTOCOL.md §4 CURSOR_STATE "Onay grubu". Dal tabanı: `task/0036-cursor-ack-integration`.

## Kapsam

1. **Kodlama/çözme:** `CURSOR_STATE` için 30 baytlık biçim (`rel_ack_count` u64, sonda). Grup `0` ise yazılmaz (22 bayt). Çözücü: 22 bayt grupsuz, 23–29 bayt protokol hatası, ≥30 bayt grup okunur. Fixture testleri: `cursor_state_ack`, `invalid_cursor_state_ack_partial`; mevcut `cursor_state*` değişmeden geçer.
2. **Onay değeri:** kontrol bağlantısı başına işlenen `POINTER_REL` mesajlarının sayısı (düğme değişimli `dx = dy = 0` mesajlar dahil), geliş sırasıyla. "İşlendi" şunlardan biri demek:
   - CGEvent enjekte edildi (konum ve düğme), ya da
   - 0025 bayat girdi kuralları ya da girdi kapısı onu attı.
   
   Kuyruktaki olay sayılmaz. Bağlantı başında `0`.
3. **Doğruluk (en önemli):** bir `CURSOR_STATE`'teki onay, aynı durumdaki `x`/`y`'nin o olayın etkisini içerdiğini garanti etmeli. Host konumu nereden okuyor (`CGEvent(source:nil).location`, kendi hesapladığı hedef, NSEvent…) ve CGEventPost'tan sonra konum okuması senkron mu? Bunu kodda ve gerekirse küçük bir yerel ölçümle doğrula; GUI penceresi açma. Sıra: onayı konumu okumadan **önce** al; ya da konumu enjekte edilen hedeften türet. Gerekçeyi Plan'a yaz.
4. **Akış:** onay değişince (yeni `POINTER_REL` işlendi) `CURSOR_STATE` mevcut "değişince gönder" yolundan gider; ayrı mesaj ya da yeni zamanlayıcı yok. Yeni kuyruk yok (sınırlı kuyruk kuralı).
5. Yerel imleç kapalıyken hiçbir şey değişmez.

## Kabul

- Birim testleri:
  - fixture'lar;
  - onay monotonluğu;
  - bayat atılan olayın onaylanması;
  - kuyruktaki olayın onaylanmaması;
  - onay ↔ konum sırası (sahte enjektörle).
- `./scripts/check.sh` geçer. Kotlin fixture kapsamı T-345 birleşene kadar düşebilir; handoff'ta yaz.
- Cihaz testi orkestratörde.

## Plan

## Handoff

## Açık sorular
