---
id: T-026
title: Tablet — kalem örneklerini bekletmeden ilet (unbuffered dispatch), yinelenen örnek sayacı
status: in-progress
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

- [ ] Video görünürken kalem için **bekletmesiz iletim** istenir: API 30+ `View.requestUnbufferedDispatch(int source)` (kalem kaynağı; hover dahil), olmazsa hareket başına `requestUnbufferedDispatch(MotionEvent)`. Parmak için istenmez. Hangi yolun kullanıldığı `MB/input`'a bir kez yazılır.
- [ ] İstek, girdi yakalama etkin değilken (bağlantı paneli açık) kaldırılır ya da zararsızdır; yaşam döngüsü (odak, arka plan, yeniden bağlanma) sonrasında yeniden kurulur.
- [ ] Sistem yine de toplu olay verirse davranış aynıdır: bütün örnekler sırayla tek mesajda, hiçbiri atılmaz (T-024 kuralları bozulmaz).
- [ ] **Yinelenen örnekler:** ölçümde Mac'e gelen olayların ~%25'i bir öncekiyle aynı konumdaydı (mesaj başına yaklaşık bir tane). Saniyelik özet satırına iki sayaç eklenir: `dup_exact` (zaman, konum, basınç, eğim ve bayrakları bir önceki gönderilen örnekle aynı) ve `dup_pos` (yalnız konum aynı, zaman farklı). **Yalnızca `dup_exact` olanlar gönderilmez**; durum değiştiren örnek (bayrak farkı) ve canlılık tekrarı asla atılmaz. Kaynağı kodda bulunursa (ör. güncel örneğin geçmişin son örneğiyle aynı olması) düzeltilir ve Handoff'a yazılır.
- [ ] Özet satırına `max_batch` (aralıktaki en büyük PEN örnek sayısı) eklenir; cihazda bekletmesiz iletimin çalıştığı bununla görülür (beklenen: çoğunlukla 1).
- [ ] Saf mantık JVM testli (yinelenen örnek ayıklama, sayaçlar, durum değiştiren örneğin korunması). `MotionEvent` bağlantısı derlenir; cihaz testi orkestratörde.
- [ ] `./scripts/check.sh` geçiyor.

## Notlar

- Tabletin kalemi ayrı bir girdi cihazı (`huawei,ts_pen`, source 0x5002). HarmonyOS 4.3 = API 31.
- Mesaj sayısı saniyede ~100'den ~330–420'ye çıkar; gönderim kuyruğu sınırları (§5) aynı kalır, tıkanma birleştirmesi yalnız hover için geçerlidir.
- Cihazda doğrulama: `max_batch`, `pen_msgs` ≈ `pen_samples`, ölçüm penceresinde olay aralığı p50 ≈ 3 ms, Krita'da hızlı daire.

## Plan

Küçük değişiklik, üç parça. Protokol ve host değişmez.

1. **Bekletmesiz iletim isteği** (`input/UnbufferedPenDispatch.kt`, saf politika + JVM testi; Android bağlantısı `MainActivity`'de). `Build.VERSION.SDK_INT >= 30` ise `root.requestUnbufferedDispatch(InputDevice.SOURCE_STYLUS)` (kaynak tabanlı: hover genel hareket olaylarıyla geldiği için gerekli; pencerede kalıcıdır). Daha eski API'de yedek: her kalem `ACTION_DOWN`'ında `root.requestUnbufferedDispatch(ev)` (yalnızca o vuruş). Politika: girdi yakalama etkinken (`syncInputActive`, video görünür) iste, etkin değilken `SOURCE_CLASS_NONE` ile kaldır; pencere yeniden bağlanınca (`OnAttachStateChangeListener`) ve odak dönünce yeniden kur; görünüm bağlı değilse uygulanmış sayma, sonra yeniden dene; istek istisna atarsa bir kez logla ve bırak (gruplu iletim sürer). Seçilen yol `MB/input` içine bir kez yazılır (`unbuffered path=source|per_gesture|failed`).
2. **Yinelenen örnek ayıklama** (`PenTracker`): yalnızca gerçek Android olaylarından gelen örnekler (`onFrame` yolları) son **gönderilen** örnekle karşılaştırılır. Bire bir aynıysa (zaman, x, y, basınç, eğim, bayraklar; bayraklar `!= 0` ve `STROKE_START` yok) gönderilmez ve `dup_exact` artar. `flags = 0`, `STROKE_START`, bayrağı farklı, canlılık tekrarı ve sentetik kapanış örnekleri filtreye hiç girmez (ayrı `emit` yolu). Konum aynı ama zaman farklıysa örnek gönderilir, `dup_pos` artar (`dup_pos_first`: olayın ilk örneği, yani olaylar arası; geri kalanı olay içi, kaynağı ayırmak için). Kaynak kodda aranır; bulunamazsa cihazdaki sayaçlar belirler.
3. **Sayaçlar**: `InputCounters`'a `dup_exact`, `dup_pos`, `dup_pos_first`, `max_batch` (aralıkta gönderilen en büyük PEN mesajı örnek sayısı); saniyelik `MB/input` özetine eklenir.

Testler: `PenDedupeTest` (bire bir yinelenen atılır, yalnız gönderilenle karşılaştırılır, bayrak farkı/`STROKE_START`/`flags=0`/canlılık tekrarı/DOWN-UP geçişi asla atılmaz, `dup_pos` ve `dup_pos_first`, `max_batch`, toplu olay tek mesajda sırayla, parçalama, reset sonrası), `UnbufferedPenDispatchTest` (API 30+ kaynak yolu, yedek yol, etkin olunca iste / etkin değilken kaldır, yeniden bağlanınca yeniden kur, bağlı değilken yeniden dene, istisna, yol bir kez loglanır). Mevcut `PenTrackerTest` içindeki bire bir aynı iki örneği (`pt(106), pt(106)`) farklı konuma çeviririm (artık atılıyor). Kasıtlı bozma: bayrak karşılaştırması, "son gönderilen yerine son alınan", canlılık yolunun filtreye girmesi.

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
