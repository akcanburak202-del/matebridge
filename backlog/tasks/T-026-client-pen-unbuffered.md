---
id: T-026
title: Tablet — kalem örneklerini bekletmeden ilet (unbuffered dispatch), yinelenen örnek sayacı
status: review
phase: 2
owner: android-client-dev
depends_on: [T-024]
decisions: [0004]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/input/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/input/
---

## Amaç

T-025 canlı denemesinde (2026-09-30) Krita'da hızlı çizilen daireler çokgen gibi çıktı. Ölçüm (NOTES aynı tarih): tablet saniyede ~300–420 kalem örneğini ~90–125 PEN mesajında gönderiyor; host bir mesajdaki 3–5 örneği art arda (aralık ~0,3 ms) enjekte ediyor, sonra ~14 ms boşluk oluyor. Olay birleştirmesi açık bir Mac uygulaması saniyede yalnızca 60 nokta alıyor (parça boyu 28–43 pt); kapalıyken bütün noktalar geliyor ama yine öbek öbek.

Kök neden tablette: Android kalem örneklerini ekran karesine göre topluyor. Hedef: her kalem örneği oluştuğu anda kendi `MotionEvent`'iyle gelsin ve kendi PEN mesajıyla gitsin; Mac'e ~3 ms aralıklı, eşit dağılmış ulaşsın. Yan kazanç: kalem gecikmesi bir kareye kadar azalır.

## Kapsam dışı

- Host tarafında toplu örnekleri zamana yayma (gerekirse ayrı kart; önce bunun etkisi ölçülecek).
- Protokol değişikliği yok: `count = 1` olan PEN mesajı zaten geçerli. Toplu gelen olaylar yine tek mesajda gider.

## Kabul kriterleri

- [x] Video görünürken kalem için **bekletmesiz iletim** istenir: API 30+ `View.requestUnbufferedDispatch(int source)` (kalem kaynağı; hover dahil), olmazsa hareket başına `requestUnbufferedDispatch(MotionEvent)`. Kaynak sınıfı kalem kaynağını da içeren işaretçi sınıfı olduğundan (`SOURCE_STYLUS` = kalem biti + `SOURCE_CLASS_POINTER`), girdi yakalama etkinken **işaretçi sınıfındaki bütün olaylar (parmak dahil) bekletmesiz gelir**; bu kabul edildi (karar: orkestratör, T-026 inceleme turu). Hangi yolun kullanıldığı `MB/input`'a bir kez yazılır.
- [x] İstek, girdi yakalama etkin değilken (bağlantı paneli açık) kaldırılır ya da zararsızdır; yaşam döngüsü (odak, arka plan, yeniden bağlanma) sonrasında yeniden kurulur.
- [x] Sistem yine de toplu olay verirse davranış aynıdır: bütün örnekler sırayla tek mesajda, hiçbiri atılmaz (T-024 kuralları bozulmaz).
- [x] **Yinelenen örnekler:** ölçümde Mac'e gelen olayların ~%25'i bir öncekiyle aynı konumdaydı (mesaj başına yaklaşık bir tane). Saniyelik özet satırına iki sayaç eklenir: `dup_exact` (zaman, konum, basınç, eğim ve bayrakları bir önceki gönderilen örnekle aynı) ve `dup_pos` (yalnız konum aynı, zaman farklı). **Yalnızca `dup_exact` olanlar gönderilmez**; durum değiştiren örnek (bayrak farkı) ve canlılık tekrarı asla atılmaz. Kaynağı kodda bulunursa (ör. güncel örneğin geçmişin son örneğiyle aynı olması) düzeltilir ve Handoff'a yazılır.
- [x] Özet satırına `max_batch` (aralıktaki en büyük PEN örnek sayısı) eklenir; cihazda bekletmesiz iletimin çalıştığı bununla görülür (beklenen: çoğunlukla 1).
- [x] Saf mantık JVM testli (yinelenen örnek ayıklama, sayaçlar, durum değiştiren örneğin korunması). `MotionEvent` bağlantısı derlenir; cihaz testi orkestratörde.
- [x] `./scripts/check.sh` geçiyor.

## Notlar

- Tabletin kalemi ayrı bir girdi cihazı (`huawei,ts_pen`, source 0x5002). HarmonyOS 4.3 = API 31.
- Mesaj sayısı saniyede ~100'den ~330–420'ye çıkar; gönderim kuyruğu sınırları (§5) aynı kalır, tıkanma birleştirmesi yalnız hover için geçerlidir.
- Cihazda doğrulama: `max_batch`, `pen_msgs` ≈ `pen_samples`, ölçüm penceresinde olay aralığı p50 ≈ 3 ms, Krita'da hızlı daire.

## Plan

Küçük değişiklik, üç parça. Protokol ve host değişmez.

1. **Bekletmesiz iletim isteği** (`input/UnbufferedPenDispatch.kt`, saf politika + JVM testi; Android bağlantısı `MainActivity`'de). `Build.VERSION.SDK_INT >= 30` ise `video.requestUnbufferedDispatch(InputDevice.SOURCE_STYLUS)` (kaynak tabanlı: hover genel hareket olaylarıyla geldiği için gerekli; pencerede kalıcıdır). Daha eski API'de yedek: her kalem `ACTION_DOWN`'ında `video.requestUnbufferedDispatch(ev)` (yalnızca o vuruş). Politika: girdi yakalama etkinken (`syncInputActive`, video görünür) iste, etkin değilken `SOURCE_CLASS_NONE` ile kaldır; pencere yeniden bağlanınca (`OnAttachStateChangeListener`) ve odak dönünce yeniden kur; görünüm bağlı değilse uygulanmış sayma, sonra yeniden dene; istek istisna atarsa bir kez logla ve bırak (gruplu iletim sürer). Seçilen yol `MB/input` içine bir kez yazılır (`unbuffered path=source|per_gesture|failed`).
2. **Yinelenen örnek ayıklama** (`PenTracker`): yalnızca gerçek Android olaylarından gelen örnekler (`onFrame` yolları) son **gönderilen** örnekle karşılaştırılır. Bire bir aynıysa (zaman, x, y, basınç, eğim, bayraklar; bayraklar `!= 0` ve `STROKE_START` yok) gönderilmez ve `dup_exact` artar. `flags = 0`, `STROKE_START`, bayrağı farklı, canlılık tekrarı ve sentetik kapanış örnekleri filtreye hiç girmez (ayrı `emit` yolu). Konum aynı ama zaman farklıysa örnek gönderilir, `dup_pos` artar (`dup_pos_first`: olayın ilk örneği, yani olaylar arası; geri kalanı olay içi, kaynağı ayırmak için). Kaynak kodda aranır; bulunamazsa cihazdaki sayaçlar belirler.
3. **Sayaçlar**: `InputCounters`'a `dup_exact`, `dup_pos`, `dup_pos_first`, `max_batch` (aralıkta gönderilen en büyük PEN mesajı örnek sayısı); saniyelik `MB/input` özetine eklenir.

Testler: `PenDedupeTest` (bire bir yinelenen atılır, yalnız gönderilenle karşılaştırılır, bayrak farkı/`STROKE_START`/`flags=0`/canlılık tekrarı/DOWN-UP geçişi asla atılmaz, `dup_pos` ve `dup_pos_first`, `max_batch`, toplu olay tek mesajda sırayla, parçalama, reset sonrası), `UnbufferedPenDispatchTest` (API 30+ kaynak yolu, yedek yol, etkin olunca iste / etkin değilken kaldır, yeniden bağlanınca yeniden kur, bağlı değilken yeniden dene, istisna, yol bir kez loglanır). Mevcut `PenTrackerTest` içindeki bire bir aynı iki örneği (`pt(106), pt(106)`) farklı konuma çeviririm (artık atılıyor). Kasıtlı bozma: bayrak karşılaştırması, "son gönderilen yerine son alınan", canlılık yolunun filtreye girmesi.

## Handoff

- **Commit:** dal `task/T-026-client-pen-unbuffered`. Plan `e255eb3`, uygulama `4de4f1f`, bu handoff güncellemesi dal başı. `./scripts/check.sh` -> ALL OK (gradle client-android dahil, yeni testler koştu).
- **Dokunulan dosyalar:** yeni `client/input/UnbufferedPenDispatch.kt` (saf politika); `input/PenTracker.kt` (yinelenen ayıklama + sayaçlar), `input/Model.kt` (`InputCounters`); `MainActivity.kt` (istek bağlantısı); testler `PenDedupeTest`, `UnbufferedPenDispatchTest` (yeni), `InputCaptureTest` (özet satırı testi), `PenTrackerTest` (aşağıdaki iki test verisi). Protokol, host, `MotionEventAdapter` dokunulmadı.
- **Ne yapıldı:**
  1. **Bekletmesiz iletim:** API >= 30 ise `video.requestUnbufferedDispatch(InputDevice.SOURCE_STYLUS)` (kaynak tabanlı, hover dahil, pencerede kalıcı). Girdi yakalama etkinken (`syncInputActive`: video görünür, panel gizli) istenir, etkin değilken ve `onStop`'ta `SOURCE_CLASS_NONE` ile kaldırılır; pencere yeniden bağlanınca (`OnAttachStateChangeListener`) ve odak dönünce bir sonraki senkronda yeniden istenir; görünüm bağlı değilse uygulanmış sayılmaz ve yeniden denenir; istek istisna atarsa bir kez loglanır ve gruplu iletim sürer (yeniden denenmez). API < 30 yedeği: her kalem `ACTION_DOWN`'ında `video.requestUnbufferedDispatch(ev)`. Seçilen yol bir kez `MB/input`'a yazılır: `unbuffered path=source|per_gesture|failed`.
  2. **Yinelenen ayıklama (`PenTracker.emitReal`):** yalnızca gerçek Android olaylarından gelen örnekler son **gönderilen** örnekle karşılaştırılır; zaman, x, y, basınç, eğim ve bayrak bire bir aynıysa gönderilmez (`dup_exact`). `flags = 0`, `STROKE_START` taşıyan ve bayrağı farklı olan örnek asla yinelenen sayılmaz; canlılık tekrarı ve sentetik kapanış örnekleri (`leaveAt`, `leaveAtLast`, `repeatLast`) filtreye hiç girmez (doğrudan `emit`). Konum aynı, zaman farklı örnek gönderilir, yalnızca sayılır (`dup_pos`; `dup_pos_first` = bunlardan olayın ilk örneği olanlar). Bütün örnekler yine sırayla tek mesajda gider (toplu olay = tek mesaj, 64 sınırı).
  3. **Özet satırı** sonuna: `dup_exact= dup_pos= dup_pos_first= max_batch=` (`max_batch` = aralıkta gönderilen en büyük PEN mesajının örnek sayısı).
- **Yinelenen örneklerin kaynağı:** **kodda bulamadım, düzeltme yapmadım (tahmin yok).** Bakılanlar: `MotionEventAdapter.penFrame` geçmiş örnekleri `0 until historySize` sonra güncel örneği okuyor; Android API'sinde geçmiş örnekler güncelden kesin önce gelir, kodda örtüşme yok. `PenTracker`: tekrar üreten yerler yalnızca canlılık tekrarı (100 ms sessizlikte) ve `ACTION_UP`'ın son konumu (vuruş başına bir kez); mesaj başına bir yinelenen üretecek bir yol yok. Kalan adaylar platform tarafı (HarmonyOS güncel örneği geçmişin sonuyla aynı konumda veriyor, ya da ardışık olaylar örtüşüyor) ve Mac tarafı: NOTES'te Mac'te ~480 olay/sn ölçülmüş, tablet 300–420 örnek/sn gönderiyor; Mac'e tabletin gönderdiğinden fazla olay gelmiş olması, fazlalığın en azından bir kısmının tabletten sonra (host enjeksiyonu ya da macOS) eklendiğini düşündürüyor (ölçümler aynı oturumdan olmayabilir, kesin değil; host'ta `penDrag` örnek başına bir olay üretiyor, fazladan bir şey görmedim). Cihazdaki sayaçlar ayırır (aşağıda).
- **Varsayımlar:**
  1. `View.requestUnbufferedDispatch(int)` API 30'da eklenmiş (SDK `api-versions.xml`'den doğrulandı: `since="30"`; `minSdk` 29 olduğundan Build.VERSION koruması var). `SOURCE_STYLUS` (0x4002) `SOURCE_CLASS_POINTER` bitini de taşıdığından platform bunu "kaynak & istek != 0" ile karşılaştırıyorsa (AOSP'de böyle olduğunu hatırlıyorum, burada doğrulayamadım) **parmak (dokunmatik ekran) olayları da bekletmesiz gelebilir**. Zararsız (parmak izcisi olay başına çalışıyor, kaydırma deltaları toplanmadan gelir), ama `touch_msgs` artabilir; kalem dışı kaynağı ayırmanın bu API'de yolu yok.
  2. Kaynak isteği `ViewRootImpl`'de kalıcı ve kendiliğinden sonlanmaz (View belgesi); bu yüzden panel görünürken kaldırılıyor.
  3. Gönderim kuyruğu 300–420 mesaj/sn'yi tıkanmadan taşır (mesaj ~40 bayt); tıkanma birleştirmesi yalnızca hover içindir ve değişmedi. Cihazda `merged`/`refused` izlenecek.
  4. `dup_pos` tanımı bayrak farkını hesaba katmaz (konum aynı + zaman farklı olan her gerçek örnek; vuruş başında hover ile aynı konuma inen örnek gibi nadir durumlar dahil; gürültü düzeyinde). Sentetik örnekler (canlılık, kapanış) sayılmaz.
  5. `isExactDuplicate` içindeki `flags != 0` ve `STROKE_START` korumaları savunma amaçlı: izleyici bugünkü akışta ardışık iki `STROKE_START` ya da iki `flags=0` örneği filtreden geçirmiyor (ikisi `emit` yolunda), yani mutasyonla kırılmıyorlar; kural açık kalsın diye durdular.
- **Testler:** `PenDedupeTest` (17): bire bir yinelenen atılır ve `dup_exact` artar; olay içi yinelenenler atılır, kalan sırayla ve `dt_us` doğru; karşılaştırma yalnız son gönderilenle; basınç/eğim farkı yinelenen sayılmaz; reset sonrası gönderilir; tamamı yinelenen olay hiçbir şey göndermez ve canlılık saatini beslemez; bayrak farkı (hover/DOWN/MOVE/UP aynı zaman-konumda) asla yinelenen değil; tekrarlanan DOWN'da `STROKE_START` gider; `flags = 0` (iki CANCEL) gider; **kablo üzerinde bire bir aynı canlılık tekrarı gönderilir**; kapanış örneği süzülmez; `dup_pos`/`dup_pos_first`; `max_batch` (1, 4, 64 bölme, sıfırlama); tek örnekli olaylar bire bir mesaj; toplu olay tek mesaj sırayla. `UnbufferedPenDispatchTest` (8): yol seçimi (API 29/30/31), tek istek + bir kez log, etkin değilken kaldırma ve hiç etkin olmamışken çağrı yok, bağlı değilken yeniden deneme, yeniden kurma, istisna, eski API yolu. `InputCaptureTest`: özet satırında yeni alanlar, `pen_msgs == pen_samples`. **Kasıtlı bozma** (her biri ilgili testi kırdı, sonra geri alındı): bayrak eşitliği kontrolü kaldırıldı -> `aSampleWithDifferentFlagsIsNeverADuplicate...`; canlılık tekrarı filtreye sokuldu -> `aLivenessRepeatIsSentEvenWhen...` ve özet testi; zaman karşılaştırması kaldırıldı -> 11 test; referans olay içinde ilerlemiyor -> `identicalContactSamplesInsideOneEvent...` ve `samePositionWithADifferentTime...`. Mevcut testlerde iki veri değişti: `PenTrackerTest.allHistoricalSamples...` içindeki ikinci `pt(106)` ve `repeatTimestampsNeverGoBackwards` içindeki geç örnek artık farklı konumda (aksi halde bire bir yinelenen olur ve atılırdı; testlerin amacı değişmedi).
- **Test edilmeyenler / cihazda doğrulanacaklar** (cihazda hiçbir şey çalıştırılmadı; `MainActivity` bağlantısı yalnızca derlendi):
  1. Yükle, bağlan, video gelince `adb logcat -s MB/input`. **Bir kez** `unbuffered path=source` görülmeli (video görünür olunca). `path=failed` ya da hiç satır yok = istek uygulanmadı.
  2. **Kalemle çizerken** (boşta hover'da değil) saniyelik `ev=stats` satırı: `max_batch` çoğu saniyede **1** (önceden 3–5); tek bir saniyede 2–3 görülebilir (tek bir takılma), sürekli >= 3 ise sistem hâlâ topluyor demektir. `pen_msgs` ≈ `pen_samples` (ikisi de ~300–420/sn; önceden mesaj ~90–125/sn). Mac tarafındaki ölçüm penceresinde olay aralığı p50 ~3 ms, öbek yok. Krita'da hızlı daire.
  3. **Yinelenenler:** `dup_exact` çoğunlukla 0 olmalı (gerçek bire bir yinelenen platformda nadirdir; büyükse platform aynı olayı iki kez teslim ediyor demektir ve artık atılıyor). `dup_pos` çizim sırasında pen_samples'ın ~%25'i kadar ise yinelenen konumlar **tabletten geliyor** (platform tekrar konum veriyor; bekletmesiz iletimle olay başına bir örnek geldiğinden `dup_pos_first` ~ `dup_pos` olur, olay içi/olaylar arası ayrımı ancak `max_batch > 1` iken yapılabilir: orada `dup_pos_first` ~ 0 ve `dup_pos` > 0 ise güncel örnek geçmişin son konumunu tekrarlıyor). `dup_exact` ve `dup_pos` ikisi de ~0 iken Mac'te yine ~%25 aynı konumlu olay varsa kaynak **tablet dışında** (host enjeksiyonu ya da macOS).
  4. Yan etki kontrolleri: `merged`, `refused`, `hover_stale`, `contact_stale` 0 kalmalı; `exit_absorbed` her vuruşta artmaya devam etmeli; iki parmak kaydırma sırasında `touch_msgs` artabilir (yukarıdaki varsayım 1), Mac'te kaydırma yine düzgün olmalı ve takılı kalan olmamalı.
  5. Takılı girdi denemeleri (T-024 ile aynı): vuruş sırasında Home, bildirim çubuğu, USB'yi çek/Wi-Fi'yi kes -> Mac'te basılı kalem/düğme yok. Panel açılınca (bağlantı koparsa) istek kaldırılır: panelde normal dokunma çalışmalı.
- **Açık sorular:**
  1. `docs/LOGGING.md` özet satırı alanlarını saymıyor, güncelleme gerekmedi; alanlar `Model.kt: InputCounters.fields` içinde.
  2. Kaynak tabanlı isteğin parmağı da bekletmesiz yapması (varsayım 1) sorun çıkarırsa ayrı karar: kalem `DOWN`'ında `requestUnbufferedDispatch(MotionEvent)` + hover için ayrı yol gerekir.
  3. Yinelenen örneklerin kaynağı cihazdaki sayaçlara kaldı (yukarıda); tabletten geliyorsa `dup_pos` örneklerini de göndermemek ayrı bir karar (konum aynı ama basınç/eğim/zaman farklı olduğundan bu kart yalnızca bire bir yinelenenleri atıyor).
