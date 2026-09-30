---
id: T-043
title: Mac — eşleşme onayı tablet ayrılınca kaybolmasın (ön onay), Parsec'ten onaylanabilsin
status: review
phase: 4
owner: mac-host-dev
depends_on: [T-041]
decisions: [0010]
files:
  - host-mac/Sources/MateBridgeCore/Session/
  - host-mac/Sources/MateBridgeCore/Crypto/PairKeyService.swift
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

- [ ] **T-041 son Codex turundan (P2):** (a) terk edilen eşleşmenin temizliği (`finishPairing` → `remove(device)`) aynı cihaz için sonradan kaydedilen **daha yeni** anahtarı silmemeli: yalnızca kendi kaydettiği anahtar hâlâ duruyorsa silsin (karşılaştır-ve-sil ya da nesil sayacı). (b) `PairKeyService` bekleyen işleri sınırlı olmalı (ör. en çok 8 bekleyen arama; fazlası → o bağlantı kapanır) ve bağlantısı kapanmış/süresi dolmuş aramalar çalıştırılmadan atlanmalı. İkisi de testli.

- [ ] Yukarıdaki 1–4, saf durum makinesinde testli (zaman sahte saatle): ayrılan bekleyen istek, ön onayla yeniden bağlanma → ACCEPTED, süresi dolmuş ön onay → normal onay, tek kullanım, reddet.
- [ ] Ön onay yalnızca PAIRING için; PAIRED akışı ve devralma (kanıt) kuralları değişmez.
- [ ] Onay penceresi durumu güncellenir; "İzin ver" bağlantı yokken de çalışır.
- [ ] `./scripts/check.sh` geçiyor.

## Kapsam dışı

- Tablet değişikliği yok (tablet zaten yeniden bağlanıyor ve PAIRING'de ACCEPTED gelince anahtarı saklıyor).
- Cihaz testi orkestratörde: tablet kodu gösterirken Parsec'e geç, Mac'te izin ver, MateBridge'e dön → eşleşir.

## Plan

1. **Makine (`SessionMachine`, saf):** yeni `orphan` (ayrılan bekleyen istek: conn id, device, ad, kod yok, bitiş = ayrılma + 2 dk) ve `preapprovals: [DeviceID: bitiş]`. Bekleyen bağlantı `connectionClosed` ya da `BYE` ile biterse `.cancelApproval` yerine yeni `.approvalOrphaned(conn)` üretilir (pencere kalır). Protokol hatası / kayıt doğrulama hatası / shutdown / 60 sn zaman aşımı eskisi gibi iptal eder.
2. `approvalDecided(conn)` bağlantı yoksa ama `orphan` o conn ise: "İzin ver" -> `preapprovals[device] = now + 2 dk` (+ log), "Reddet" -> ön onay yok (varsa o cihazınki silinir); ikisinde de `.cancelApproval`. Orphan `tick`te süresi dolunca `.cancelApproval` ile kapanır; her yeni `requestApproval` eski orphan'ı önce iptal eder (eski ön onaya dokunmaz). `forgetApprovedDevices` ön onayları ve orphan'ı da siler.
3. `continueHello` PAIRING dalı: geçerli ön onay varsa tüketilir (tek kullanım; süresi dolmuşsa silinir ve normal onay), ilk ACK + `persistPairing` üretilir, `requestApproval` yok, log `approval_preapproved`. PAIRED dalı ve devralma kuralı değişmez; ön onay yalnız PAIRING'de tüketilir.
4. **Sunucu/UI:** `Handlers.approvalOrphaned`, `ApprovalPanel.markDisconnected()` ("Tablet ayrıldı. İzin verirsen tablet yeniden bağlandığında eşleşir."), `main.swift` bağlama.
5. **P2 (a):** `PairKeyService.remove(_:ifEquals:)` kuyrukta karşılaştır-ve-sil; `finishPairing` kendi kaydettiği anahtarı iletir. **P2 (b):** `PairKeyService.lookup` en çok 8 bekleyen arama (fazlası `false` döner, sunucu o bağlantıyı kapatır) ve `isCurrent` denetimi: bağlantı kapanmış/5 sn dolmuş arama Keychain'e gitmeden atlanır.
6. **Testler:** sahte saatli makine testleri (ayrılma, ön onayla yeniden bağlanma, süre dolumu, tek kullanım, reddet, değiştirme, PAIRED etkilenmez, forget) + PairKeyService (sınır, bayat atlama, karşılaştır-ve-sil, yeni anahtar korunur).
Not: `PairKeyService.swift` (Core/Crypto) kartın `files:` listesinde yok ama P2 düzeltmesi onu gerektiriyor; yalnız o dosyaya dokunuldu (Açık sorular).

## Tasarım revizyonu (tur 1, Codex P1)

`device_id`'ye bağlı ön onay kaldırıldı (LAN saldırganı düz metin `device_id`'yi kopyalayıp kendi geçici anahtarıyla tüketebilirdi). Yeni tasarım (PROTOCOL §9 "Bağlantı koptuktan sonra onay"): ayrılan bekleyen isteğin penceresi aynı kodla 2 dk açık kalır ve o el sıkışmanın `new_pair_key`'i + cihaz adı bellekte tutulur. "İzin ver" -> anahtar + onay kaydı seri `PairKeyService` üzerinden saklanır (ACCEPTED yok); reddet/süre dolumu/yeni istekle değiştirme -> hiçbir şey saklanmaz, anahtar bellekten düşer. Cihazın sonraki bağlantısı normal aramayla PAIRED olur; el sıkışmayı yalnız o anahtarı tutan tablet (T-044) tamamlayabilir. Yukarıdaki Amaç 2-3 maddeleri (ön onay) bu revizyonla geçersizdir.

## Handoff

- **Commit:** dal ucu `task/T-043-host-pairing-preapproval` (plan, ilk uygulama, main merge, revizyon ayrı commit'ler).
- **Dokunulan dosyalar:** `MateBridgeCore/Session/SessionMachine.swift` (orphan: id/device/ad/`new_pair_key`/bitiş; `.approvalOrphaned`, `.persistOrphanPairing`, `orphanPairingPersisted`), `MateBridgeCore/Crypto/PairKeyService.swift` (**kartın `files:` listesinde yok**, P2 için gerekti), `MateBridgeHost/Session/SessionServer.swift`, `MateBridgeApp/ApprovalPanel.swift` + `main.swift`, testler: `Session/PairingOrphanApprovalTests.swift`, `Crypto/KeychainAsyncTests.swift` (+3), `SessionMachineTests` (1 beklenti).
- **check.sh:** yeşil.
- **Davranış:** bekleyen bağlantı `connectionClosed`/`BYE` ile biterse pencere kalır ("Tablet ayrıldı...") ve ayrılıştan 2 dk sonra kapanır; protokol hatası, kayıt doğrulama hatası, shutdown, 60 sn onay zaman aşımı eskisi gibi iptal eder. Ayrılmış pencerede "İzin ver" -> `persistOrphanPairing`: sunucu anahtarı Keychain'e (`PairKeyService.save`), sonra cihaz listesine yazar ve makine cihazı onaylı sayar; hiçbir şey gönderilmez. Sonraki bağlantı PAIRED. Reddet / süre dolumu / yeni PAIRING isteği: anahtar bellekten düşer, hiçbir şey saklanmaz. `device_id` ile otomatik kabul yok (testli). Canlı onay yolu değişmedi.
- **P2 (a):** `PairKeyService.remove(_:ifEquals:)` kuyrukta karşılaştır-ve-sil; `finishPairing` ve orphan kaydı başarısızlığı bunu kullanır.
- **P2 (b):** `lookup` en çok 8 bekleyen arama (fazlası `false`, sunucu bağlantıyı kapatır), `isCurrent` ile kapanmış/5 sn dolmuş aramalar Keychain'e gitmeden atlanır.
- **Varsayımlar:** orphan bitişi makinenin son gördüğü `now`'dan hesaplanır (`connectionClosed` saat taşımaz, tick 100 ms). "İzin ver" ile "Onaylı cihazları unut" çakışırsa cihaz listesinde anahtarsız kayıt kalabilir; bu PAIRING'e düşer (T-041 kuralı), zararsız.
- **Test edilmeyenler / cihazda doğrulanacaklar:** `ApprovalPanel.markDisconnected`, `main.swift` bağlaması, `SessionServer` köprüleri (`finishOrphanPairing`, `liveLookups`, taşma kapatması) yalnız derlendi. Cihaz: tablet kodu gösterirken Parsec'e geç -> Mac'te "Tablet ayrıldı" + "İzin ver" -> MateBridge'e dön -> doğrudan PAIRED bağlanmalı (tablet tarafı T-044 gerekir). Reddet ya da 2 dk sonra -> yine PAIRING.
- **Açık sorular:** `PairKeyService.swift` `files:` dışında; orkestratör onaylasın.
- **Tur 2 (Codex P2, Anahtar Zinciri takılması):**
  1. Makine `persistingOrphans` tutar: orphan onayı `persistOrphanPairing` üretince o `device_id` için HELLO `BUSY` (`reason=key_storing`) olur (tablet yeniden dener, yeni PAIRING başlatıp anahtarı değiştirmez); `orphanPairingPersisted(stored:)` (başarı, hata ya da iptal) bitirir, sonra normal arama/PAIRED. Başka cihaz etkilenmez. Testli.
  2. Sunucu `revocationGeneration` ("forget" ve host kimliği değişimi artırır); her kayıt çağrısı nesli yakalar, tamamlanınca farklıysa sonuç atılır, yazılan anahtar `remove(ifEquals:)` ile silinir, makineye `stored:false` bildirilir (canlı ve orphan onayı için ikisi de). **Testsiz:** `SessionServer` Network gerektirir, yalnız derlendi.
  3. `PairKeyService` tüm bekleyen işleri sınırlar (toplam 16, arama en çok 8; `save`/`remove`/`remove(ifEquals:)`/`lookup` dolunca `false` döner, completion çağrılmaz). `removeAll` (forget) asla reddedilmez; arada başka işlem kuyruğa girmediyse bekleyen `removeAll`'a katılır (birleşir), girdiyse ikinci bir silme kuyruğa girer (sıra korunur). Sunucu: onay cevabında önce `hasCapacity` bakar; doluysa pencere açık kalır ve "Anahtar Zinciri meşgul, tekrar dene." notuyla yeniden gösterilir (`approvalKeychainBusy`); arama dolarsa bağlantı kapanır; temizlik silmeleri reddedilirse anahtar Keychain'de kalır (onaysız, sonraki eşleşmede üzerine yazılır). Testli (PairKeyService: sınırlar, reddetme, birleşme, sıra).
  - Not: yeniden gösterilen pencerede orphan ise "Tablet ayrıldı" satırı yerine yalnız meşgul notu görünür (kozmetik).
