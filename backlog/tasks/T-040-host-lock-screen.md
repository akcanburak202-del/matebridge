---
id: T-040
title: Mac — ekran kilidi ve ekran uykusu açıkken çalışma (kilit ekranında görüntü + şifre yazma, girdiyle uyanma)
status: todo
phase: 4
owner: mac-host-dev
depends_on: [T-039]
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/
  - host-mac/Sources/MateBridgeCore/
  - host-mac/Sources/MateBridgeApp/
  - host-mac/Tests/MateBridgeCoreTests/
  - backlog/tasks/T-040-host-lock-screen.md
---

## Amaç

Kullanıcı (2026-09-30): "Ekran kilidi açıkken de kullanabileceğimiz gibi tasarla; ileride ekran kilidini açabilirim." Bugün Mac'te ekran uykusu, uyku ve ekran kilidi **kapalı** (`pmset`, `sysadminctl -screenLock`), bu yüzden bu yol hiç denenmedi. Faz 0 notu: ekran uykusundan sonra kilitlenen Mac'te codesign/ScreenCaptureKit başarısız oldu, kullanıcının kilidi açması gerekti.

Hedef: kilit/ekran uykusu açıkken tablet tek başına yeterli olsun: kilit ekranını görsün, klavyeden şifreyi yazıp kilidi açsın, tablette dokunma/klavye Mac'in ekranını uyandırsın.

## Önce ölçüm (orkestratör, kullanıcı izniyle — Mac'in kilit ayarını geçici olarak açmak gerekiyor)

1. Kilit açıkken `pmset displaysleepnow` → tablette ne görünüyor (siyah / kilit ekranı / donmuş kare), host log'unda SCStream hatası var mı, yeniden deneme ne yapıyor?
2. Tablette dokunma/tuş Mac ekranını uyandırıyor mu (sentetik CGEvent'ler kullanıcı etkinliği sayılıyor mu)?
3. Kilit ekranında şifre alanına tablet klavyesiyle yazılabiliyor mu (Secure Event Input sentetik HID olaylarını engelliyor mu)?
4. Kilit açıldıktan sonra yakalama kendiliğinden geri geliyor mu?

## Kabul kriterleri (ölçüme göre kesinleşir)

- [ ] Tablet girdisi geldiğinde host `IOPMAssertionDeclareUserActivity` ile kullanıcı etkinliği bildirir (ekran uyanır; saniyede en çok bir kez).
- [ ] Ekran uykusu/kilit sırasında yakalama hatası olursa host kalıcı olarak düşmez: mevcut yeniden deneme, kilit açılınca ya da ekran uyanınca akışı geri getirir (tabletin yeniden bağlanması gerekmeden).
- [ ] Kilit ekranında klavye ve dokunma çalışır (şifre yazılabilir); çalışmıyorsa nedeni ve seçenekler NOTES'a.
- [ ] Oturum boyunca ekranı uyanık tutmak **varsayılan değil** (kilit güvenliği bozulmasın); istenirse menüde seçenek.
- [ ] **Güvenlik (kullanıcıyla konuşuldu, 2026-10-01):** kilitliyken yeni eşleşme onaylanamaz (onay penceresi kilidin arkasında; host kilitliyken PAIRING isteğini bekletir ya da reddeder, test edilir); kilit ekranında yazılan karakterler hiçbir seviyede loglanmaz; ekranı uyanık tutma varsayılan kapalı; MateBridge yeni bir izin istemez.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

_(Ölçümden sonra doldurulur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**

## Ölçüm sonucu (2026-10-01, orkestratör + kullanıcı)

NOTES 2026-10-01 ~14:10. Ekran uykusu → sanal ekran oluşturulamıyor (nil) ve tablet uyandıramıyor; kullanıcı etkinliği bildirimi ekranı uyandırıp akışı geri getiriyor; kilit ekranında Secure Event Input yüzünden sentetik klavye çalışmıyor. Kullanıcı kararı: sanal HID/root bileşen yok. Açık: (a) uyandırma düzeltmesi (risksiz), (b) Apple Watch / yerel Ekran Paylaşımı (VNC) seçenekleri kullanıcıya soruldu.
