---
id: T-291
title: Host + istemci — tekrarlayan medya hatasında yeniden kurma bütçesini istemcinin kurtarma merdiveniyle birlikte tasarla
status: done
phase: 6
owner: orchestrator
depends_on: [T-289]
decisions: [0019]
files:
  - backlog/tasks/T-291-rebuild-budget-with-client-ladder.md
---

## Amaç

T-289 codex incelemelerinden (2026-10-07) ayrıldı. Host'un pipeline yeniden deneme bütçesi (`PipelineRetryPolicy`) yalnız kendi zamanlayıcısıyla yapılan yeniden kurmaları sınırlıyor. Tablet videoya yeniden bağlanınca `onVideoAttached` pipeline'ı koşulsuz kuruyor; bu T-289'dan önce de böyleydi. Kalıcı bir kodlayıcı hatasında döngü saniyede ~1–2 kez dönebilir: pipeline kurulur, düşer, tablet 500 ms sonra yeniden bağlanır. T-200 bitene kadar her turda sanal ekran da yeniden kuruluyor.

Host tarafında yeniden bağlanmayı bekletme denendi (T-289 cf8962f6) ve geri alındı, çünkü iki sorun çıktı:
- tabletin `VideoHealth` merdiveni ~6 sn sonra oturumu yeniden kuruyor; bu politikayı sıfırladığı için bekleme boşa çıkıyor;
- eski bir zamanlayıcı olayı, yeni kurulan bağlantıyı iptal edebiliyor.

Cihazda hiç görülmedi.

## Kabul

1. Önce tasarım notu. İki taraf "kalıcı medya hatası" durumunu tek yerde mi tanıyacak, yoksa host bunu bir STREAM_CONFIG/BYE nedeniyle mi bildirecek? Protokol değişirse bu orkestratörün işi (PROTOCOL.md ve fixture'lar). T-200 ekranı koruyorsa döngünün bedeli küçülür; bu, kartın gerekliliğini de değiştirir.
2. Kalıcı hata altında video kalıcı olarak ölü kalmaz (Mac'in tek ekranı tablet), ve yeniden kurma sıklığı sınırlı olur.
3. Uygulama kartları tasarımdan sonra açılır.

## Plan

### Tasarım notu (2026-10-08, orkestratör)

**Bugünkü döngü** (kod haritası, `main` @ `631d06a3`):
- Host: `PipelineRetryPolicy` (60 sn'de 3 deneme, 1/2/4 sn) yalnız `onPipelineFailed` içinde danışılıyor. `onVideoAttached` (`StreamCoordinator.swift:530-568`) pipeline yoksa politikaya bakmadan kuruyor. Başlatma hataları (`createPipeline` catch, `display_create_failed`) hiç sayılmıyor.
- Politika `onSessionStarted` (:373) içinde her oturumda sıfırlanıyor. Tabletin merdiveni +6 sn'de oturumu yeniden kurunca bütçe sıfırlanıyor. T-289'da denenen bekletme bu yüzden işe yaramadı.
- Tablet: video bağlantısı kapanınca `VIDEO_RETRY_US = 500 ms` sonra yeniden açılıyor (`SessionMachine.kt:553-562`). Bu `VideoHealth`'ten bağımsız ve `manual` durumunda da sürüyor.
- Tablet `manual` durumundayken video geri gelirse `videoFlowing` `resume_skipped` döndürüyor (`VideoHealth.kt`). Host düzelse bile görüntü ancak "Yeniden dene" ile dönüyor.
- Host hata olunca istemciye hiçbir şey göndermiyor (BYE ya da neden yok), yalnız video bağlantısını kapatıyor.

**Karar: protokol değişmez.** Kalıcı hatayı tanıyan tek yer host'tur. Tablet yalnızca "kare gelmeyen video bağlantısı" gözlemine tepki verir. Gerekçe:
- Yeni bir BYE nedeni oturumu kapatır, ama burada kontrol oturumu sağlıklı ve girdi kapısı zaten `VideoHealth`'te. Ayrıca eski istemci bilinmeyen nedende `lose(HOST_CLOSED)` ile yeniden bağlanır, yani döngü sürer.
- STREAM_CONFIG'de boş alan yok. Sona alan eklemek iki tarafta fixture değişikliği ister; kazancı yalnız daha doğru bir katman metni olur.
- Döngüyü kırmak için bilgi gerekmiyor, yalnızca hız sınırı gerekiyor. Bunu her iki taraf yerel olarak yapabilir.

**Host: devre kesici (T-293).**
1. `PipelineRetryPolicy` aynı cihazın yeni oturumunda **sıfırlanmaz**. Sıfırlama koşulları: başka bir cihaz (devralma), Mac uyanması (mevcut uyanma olayı; uyku/uyanma sınırındaki hata patlaması sonraki açılışı geciktirmesin), pipeline'ı değiştiren bir STREAM_PREFS ya da mod değişikliği (kullanıcı farklı bir şey denedi).
2. `.giveUp` sonrasında politika **açık** durumda kalır ve `openUntil = şimdi + bekleme` olur. Bekleme her ardışık açılışta 10 → 20 → 30 sn (tavan 30 sn). Mac'in tek ekranı tablet olduğu için tavan kısa tutuldu.
3. `onVideoAttached`, pipeline yoksa önce politikaya sorar (`admit(now) -> build | refuse(remainingMs)`). `refuse` olursa bağlantıyı **hemen** kapatır: ekran ya da kodlayıcı kurulmaz. Zamanlayıcı da yok; T-289'daki eski zamanlayıcı yarışı oluşmaz. Süre dolunca gelen ilk bağlantı **deneme kurulumu** olur. Başarısız olursa bir sonraki bekleme basamağına geçilir.
4. "Başarı" zamanlayıcısız, tembel ölçülür. Bir hata geldiğinde pipeline o ana kadar ≥ 10 sn ayakta kaldıysa, geçmiş ve bekleme basamağı hata kaydedilmeden önce temizlenir (eski hatalar zaten 60 sn penceresinden düşüyor).
5. Başlatma hataları (`createPipeline` kendi HDR/packed/oyun ekranı geri düşüşlerinden sonra yine başarısızsa) aynı politikaya `.start` türüyle kaydedilir.
6. Loglar: `pipeline_rebuild_refused remaining_ms= level=` (ilk ret ve her 10. ret, log taşmasın), `pipeline_breaker state=open|probe|closed wait_ms=`.
7. Kapsam dışı: `onPipelineFailed` içindeki olay döngüsünü bloklayan geri çekilme beklemesi (:705) olduğu gibi kalır. Ekran ömrü T-200'ün işi.

**Tablet: geri çekilme ve manuel durumdan dönüş (T-294).**
1. Video yeniden açma geri çekilmesi: üst üste 3 video bağlantısı hiç VIDEO_FRAME almadan kapanırsa bekleme 500 ms → 1 → 2 → 4 sn olur (tavan 4 sn). İlk VIDEO_FRAME ya da "Yeniden dene" ile sıfırlanır. Olağan yeniden bağlanma ve göç (ilk deneme kare alır) etkilenmez. Tavan (4 sn), host'un deneme kurulumunu en çok 4 sn geciktirir.
2. `manual` durumda `videoFlowing`, en çok **10 sn'de bir** `RESTART_CODEC` döndürür (`step=manual_resume`). Host'un deneme kurulumu başarılı olunca görüntü dokunmadan döner. Bu, 0019'un "manual'da resume yok" sınırını hız sınırıyla gevşetir (karar 0019'a uygulama notu). İzin verilen 10 sn'de bir resume, yarı başarılı bağlantılarda bile en çok 0,1 IDR/s demek.
3. Girdi kapısı değişmez: resume yeni bir kuşak başlatır, kuşak ilk çözülmüş çıktıya kadar STARTING'dedir ve girdi kapalıdır.

**T-200 ilişkisi:** T-291 T-200'e bağlı değil. T-200 ekranı korursa her deneme kurulumunun bedeli küçülür, ama kodlayıcı döngüsü yine sınır ister. Bağımlılık listeden çıkarıldı.

**Beklenen davranış, kalıcı kodlayıcı hatası altında:** ilk dakikada 4 kurulum (bugünkü bütçe), sonra en çok 10/20/30 sn'de bir deneme kurulumu. Tablet 500 ms yerine en çok 4 sn'de bir bağlanır, her ret ucuzdur. Tablet "Görüntü durdu" katmanındadır, girdi kapalıdır, host düzelince görüntü kendiliğinden döner.

**Uygulama kartları:** T-293 (host, `mac-host-dev`), T-294 (tablet, `android-client-dev`). Bağımsızlar, paralel yürüyebilirler. Codex incelemesi ikisinde de (girdi kapısı ve kurtarma).

## Handoff

Tasarım kartı; kod yok. Uygulama: T-293, T-294.

## Open questions
