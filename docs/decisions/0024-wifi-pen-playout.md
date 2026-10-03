# 0024 — Wi-Fi'de kalem örneklerini zamana yayma (deneysel, sınırlı)

- **Durum:** önerildi
- **Tarih:** 2026-10-03

## Bağlam
Kaynak: dış mimari incelemesi 2026-10-03 (HEAD a30c769), M04, IN8 ve D7. Doğrulama: `docs/reviews/2026-10-03/verify-G-input.md` (M04, P-M04c). Rapordaki "0018" taslağı bu numarayla yeniden numaralandı.

Kalem örneklerinin zaman aralıkları telde var. PEN mesajı `base_time_us` ve örnek başına `dt_us` taşıyor (PROTOCOL §4 PEN, `PenTracker.kt:350-358`). Çözünürlük 1 ms.

Host bu aralıkları kullanmıyor:
- `InputStateMachine+Pen.swift:16-24` örnekleri arka arkaya işliyor.
- `CGEventPoster.swift:33-63` hepsini tek döngüde gönderiyor.
- CGEvent zaman damgası hiç ayarlanmıyor.

Wi-Fi'de olaylar Mac'e öbekler hâlinde geliyor: aralık medyanı 0,5–1,1 ms, p95 ~10 ms. USB'de aralık düzenli, 2,8 ms (NOTES 2026-09-30). Bu ölçüm T-111'den önce, Network.framework ile ve Mac de Wi-Fi'deyken yapıldı. T-111 sonrası tekrar ölçülmedi.

Kalite kazancı kanıtlanmadı. Krita çalışmasında hiçbir olay zamanlaması değişikliği işe yaramadı; Krita'nın "tablet sürücüsü zaman damgalarını kullan" ayarı da dahil. İşe yarayan tek şey Krita yumuşatmasını kapatmaktı (NOTES 2026-09-30).

Bu iş zaten PLAN Aşama 5'te. Kullanıcı kararı, 2026-09-30: "acelesi yok, en sona". Kullanıcı çizim için USB kullanıyor.

## Seçenekler
- **(a) Zamana yayma yok.** Bugünkü durum ve kullanıcının "en sona" kararı.
- **(b) Host, PEN örneklerini `dt_us` aralıklarıyla enjekte eder (önerilen, yalnızca deney olarak).** Kurallar:
  - Eklenen gecikme en çok 12 ms.
  - Yalnızca loopback olmayan bağlantılarda çalışır. USB hemen gönderir.
  - `MATEBRIDGE_PEN_PLAYOUT_MS` ayarının arkasındadır; varsayılan 0, yani kapalı.
  - Her durum sınırı kuyruğu hemen boşaltır: CONTACT 1→0, IN_RANGE→0, araç değişimi, release-all, bekçi, oturum sonu, ve sıranın korunması için PEN dışı her girdi mesajı.
  - Bütçe aşılırsa sınırsız beklemek yerine hemen gönderime düşer.
  - Hiçbir kalkış olayı bütçeden fazla gecikmez.
- **(c) Ayrıca CGEvent zaman damgaları yeniden yazılır.** Reddedildi: NOTES, Krita'nın zaman damgası seçeneğinin işe yaramadığını gösteriyor.

## Karar
Önerilen: **(b)**, yalnızca deney olarak ve varsayılanı kapalı.

Varsayılan olarak benimsenmesi için Wi-Fi'de yapılacak bir A/B karşılaştırması, çizgi kalitesindeki kazancın eklenen gecikmeden ağır bastığını göstermeli. Bu, Krita'da yumuşatma kapalıyken ve T-171 yaş verisiyle ölçülür.

Deneye başlama koşulu: T-179 ölçümü, T-111 sonrasında öbeklenmenin sürdüğünü göstermeli.

**Kullanıcı onayı bekliyor.** Kullanıcının cevaplaması gereken (manifest §5 soru 9): Wi-Fi'de kalem hâlâ "acele yok, en sona" mı? Çizimi USB ile yaptığını söylemiştin. T-179 ve T-198 park hâlinde kalabilir.

## Sonuçlar
- **Kazanılan:** Wi-Fi'de ağ kaynaklı öbeklenme ortadan kalkabilir. USB gecikmesine ve girdi güvenliğine dokunulmaz.
- **Kaybedilen:** deney açıkken Wi-Fi'de en çok 12 ms ek kalem gecikmesi. Girdi kuyruğunda zamanlayıcı karmaşıklığı artar (oturum kuyruğu asla bloklanmamalı).
- **Kapıladığı kart:** T-198 (kalem zamana yayma deneyi). T-179'a (Wi-Fi kalem ritmi ölçümü) ve T-171'e (girdi yaşı) bağlı.
- **Mevcut kararlar:** değişmez. 0007 (kalem teması doğrulanmadan gönderilmez) ve sıralı akış kuralları korunur.
- **PROTOCOL.md:** değişmez. Var olan `dt_us` kullanılır. §7 girdi güvenliği kuralları aynı kalır, çünkü kalkışlar hemen boşaltılır.
- **Tekrar düşünülür:**
  - T-179 öbeklenme göstermezse karar düşer.
  - A/B kazanç gösterirse varsayılan "açık (Wi-Fi)" olarak yeniden önerilir.
