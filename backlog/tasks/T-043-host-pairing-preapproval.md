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

## Handoff

- **Commit:** kod + testler + bu Handoff tek commit'te (SHA orkestratöre raporda). Dal `task/T-043-host-pairing-preapproval`, plan ayrı commit.
- **Dokunulan dosyalar:** `MateBridgeCore/Session/SessionMachine.swift` (orphan + ön onay, yeni `.approvalOrphaned` eylemi, `orphanWindowUs`/`preapprovalUs` ayarları), `MateBridgeCore/Crypto/PairKeyService.swift` (**kartın `files:` listesinde yok**, P2 düzeltmesi bunu gerektirdi), `MateBridgeHost/Session/SessionServer.swift`, `MateBridgeApp/ApprovalPanel.swift` + `main.swift`, testler: yeni `Session/PairingPreapprovalTests.swift`, `Crypto/KeychainAsyncTests.swift` (+3), `SessionMachineTests` (1 beklenti güncellendi: ayrılan bekleyen bağlantı artık `cancelApproval` yerine `approvalOrphaned`).
- **check.sh:** yeşil (482 Swift testi, gradle, fixture/vektör).
- **Davranış:** bekleyen bağlantı `connectionClosed` ya da `BYE` ile biterse pencere kalır ("Tablet ayrıldı. ..." satırı), ayrılıştan 2 dk sonra kapanır. Protokol hatası, kayıt doğrulama hatası, shutdown, 60 sn onay zaman aşımı eskisi gibi iptal eder. Ayrılmış pencerede "İzin ver" -> `preapprovals[device] = şimdi + 2 dk` (bellekte). Aynı `device_id`'nin PAIRING HELLO'su geçerli ön onayı tüketir (tek kullanım), pencere açmadan ilk ACK(PENDING) + `persistPairing` üretir, ACCEPTED T-041'deki gibi yalnız anahtar saklandıktan sonra gider (`approval_preapproved` logu). Süresi dolmuşsa silinir, normal onay. Reddet -> ön onay silinir, pencere kapanır. Yeni bir `requestApproval` eski pencereyi önce iptal eder (eski ön onaya dokunulmaz). `forgetApprovedDevices` ön onayları, `shutdown` açık pencereyi siler. PAIRED ve devralma yolu değişmedi (ön onay yalnız PAIRING'de tüketilir).
- **P2 (a):** `PairKeyService.remove(_:ifEquals:)` kuyrukta karşılaştır-ve-sil; `finishPairing` (terk edilen eşleşme ve `store_save_failed`) kendi anahtarını geçer. Test: daha yeni anahtar korunur, kendi anahtarı silinir.
- **P2 (b):** `PairKeyService.lookup` en çok 8 bekleyen arama (`maxPendingLookups`), fazlası `false` döner ve sunucu o bağlantıyı (hiçbir şey gönderilmemişken) kapatır (`pair_key_lookup_overloaded`). `isCurrent` denetimi iş kuyrukta öne gelince yapılır: bağlantı kapanmış ya da 5 sn dolmuş arama Keychain'e gitmez, completion çağrılmaz. Sunucu tarafında bağlantı -> canlı kümesi (`LockedSet`).
- **Varsayımlar:** ayrılma anı, makinenin son gördüğü `now`'dan alınır (`connectionClosed` saat taşımaz; tick 100 ms'de bir geldiği için sapma küçük). Ön onay saati "İzin ver" tıklandığı andan başlar. Başka bir cihazın yeni PAIRING isteği de açık pencereyi değiştirir (tek pencere var).
- **Test edilmeyenler / cihazda doğrulanacaklar:** `ApprovalPanel.markDisconnected` (yeniden boyutlama, turuncu satır) ve `main.swift` bağlaması yalnız derlendi. Sunucu köprüleri (`approvalOrphaned` el, `liveLookups`, taşma kapatması, `finishPairing` compare-and-delete) Network/Keychain gerektirdiği için yalnız derlendi. Cihaz testi: tablet kodu gösterirken Parsec'e geç -> Mac'te pencerede "Tablet ayrıldı" satırı + "İzin ver" -> MateBridge'e dön -> sormadan eşleşmeli; 2 dk sonra ya da ikinci denemede yeniden sormalı.
- **Açık sorular:** `PairKeyService.swift` kartın `files:` listesi dışında (Core/Crypto); P2 için zorunluydu, orkestratör onaylasın. PROTOCOL §9 notu orkestratörde.
