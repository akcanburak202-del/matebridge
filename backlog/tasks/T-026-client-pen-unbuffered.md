---
id: T-026
title: Tablet — kalem örneklerini bekletmeden ilet (unbuffered dispatch), yinelenen örnek sayacı
status: todo
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

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
