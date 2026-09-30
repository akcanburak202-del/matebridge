---
id: T-043
title: Mac — eşleşme onayı tablet ayrılınca kaybolmasın (ön onay), Parsec'ten onaylanabilsin
status: todo
phase: 4
owner: mac-host-dev
depends_on: [T-041]
decisions: [0010]
files:
  - host-mac/Sources/MateBridgeCore/Session/
  - host-mac/Sources/MateBridgeHost/Session/
  - host-mac/Sources/MateBridgeApp/
  - host-mac/Tests/MateBridgeCoreTests/
  - backlog/tasks/T-043-host-pairing-preapproval.md
---

## Amaç

Şifreleme cihaz denemesi (2026-09-30): Mac başsız, kullanıcı Mac'i yalnızca tablet üstünden (MateBridge ya da Parsec) görüyor. Eşleşme (PAIRING) sırasında Mac ekranı henüz tablete gelmiyor, onay penceresi görünmüyor. Kullanıcı Parsec'e geçince MateBridge arka plana düşüp `BYE` gönderiyor, host onay penceresini kapatıyor, eşleşme olmuyor. İlk eşleşmeyi orkestratör Erişilebilirlik ile yaptı.

Çözüm (yalnız host, tel biçimi değişmez; PROTOCOL §9 notu orkestratörde):
1. Onay bekleyen bağlantı kapanırsa pencere **kapanmaz**: "Tablet ayrıldı. İzin verirsen tablet yeniden bağlandığında eşleşir." satırı eklenir; pencere en çok 2 dk açık kalır.
2. Kullanıcı bu pencerede "İzin ver" derse (bağlantı yaşıyorsa bugünkü gibi hemen kabul), bağlantı yoksa o `device_id` için **2 dk'lık ön onay** kaydedilir (bellekte, kalıcı değil).
3. Ön onay varken aynı `device_id` ile gelen PAIRING el sıkışması Mac'e sormadan kabul edilir (`approval_preapproved` logu; anahtar saklama ve ACCEPTED sırası T-041'deki gibi). Ön onay tek kullanımlıktır ve süresi dolunca silinir. Reddet → ön onay yok, pencere kapanır.
4. Aynı `device_id` için yeni bir PAIRING bekleyen istek gelirse eski pencere yenisiyle değiştirilir (yeni kodla); eski ön onay silinmez.

## Kabul kriterleri

- [ ] Yukarıdaki 1–4, saf durum makinesinde testli (zaman sahte saatle): ayrılan bekleyen istek, ön onayla yeniden bağlanma → ACCEPTED, süresi dolmuş ön onay → normal onay, tek kullanım, reddet.
- [ ] Ön onay yalnızca PAIRING için; PAIRED akışı ve devralma (kanıt) kuralları değişmez.
- [ ] Onay penceresi durumu güncellenir; "İzin ver" bağlantı yokken de çalışır.
- [ ] `./scripts/check.sh` geçiyor.

## Kapsam dışı

- Tablet değişikliği yok (tablet zaten yeniden bağlanıyor ve PAIRING'de ACCEPTED gelince anahtarı saklıyor).
- Cihaz testi orkestratörde: tablet kodu gösterirken Parsec'e geç, Mac'te izin ver, MateBridge'e dön → eşleşir.

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
