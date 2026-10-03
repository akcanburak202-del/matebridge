# 0019 — Girdi yalnızca görüntü sağlıklıyken açık

- **Durum:** kabul (2026-10-03)
- **Tarih:** 2026-10-03

## Bağlam
Kaynak: dış mimari incelemesi 2026-10-03 (HEAD a30c769), H02, SE4, X3, D3 ve F2. Doğrulama: `docs/reviews/2026-10-03/verify-B-client-video.md` (H02, SE4, P1). Bulgu doğrulandı (High; tablet tek ana ekran).

Tablette çözücü durursa görüntü donar ya da kararır, ama kalem ve tuşlar Mac'e gitmeye devam eder. Kullanıcı göremediği bir pencereye yazabilir ya da sürüklemeyi yanlış yerde sürdürebilir. Kanıt:
- **Pes etme yalnızca loglanıyor.** `RestartPolicy` (10 sn'de 3 yeniden başlatma) tükenince `ev=give_up` yazılıyor ve çözücü iş parçacığı çıkıyor (`VideoRenderer.kt:341-355`). `onGiveUp` yalnızca log yazıyor (`MainActivity.kt:1154`).
- **Girdi kapısında görüntü terimi yok.** Kapı `syncInputActive` (`MainActivity.kt:643-649`). Paneli gizleyen `streaming` ise TCP'den **alınan** kareyi sayıyor, çözüleni değil (`MainActivity.kt:1884`, `SessionController.kt:842`).
- **Sessiz hata da var.** T-028'de çözücü hata vermeden hiç çıktı üretmedi (`recv=59 dec=0`). Pes etme hiç tetiklenmedi.
- **Yeniden bağlanmada kapı erken açılıyor.** Kare sayacı sıfırlanmadığı için girdi, yeni oturumun ilk karesi çözülmeden açılıyor (`SessionMachine.kt:175/317`).
- **Pes ettikten sonra kuyruk beslenmeye devam ediyor.** STARTUP yeniden denemeleri saniyede ~2 IDR üretiyor (B ek 1).

Durağan ekran meşru olarak kare göndermez. Bu yüzden "N sn kare yok" bekçisi yanlış olur.

## Seçenekler
- **(a) Olduğu gibi kalsın.** Pes etme yalnızca loglanır ve girdi açık kalır.
- **(b) Kör bir "N sn kare yok" bekçisi.** Reddedildi: durağan ekranda yanlış alarm verir.
- **(c) Açık bir `VideoHealth` durumu (önerilen).** Girdi yalnızca görüntü HEALTHY iken açıktır. HEALTHY şu demek:
  - yüzey bağlı;
  - geçerli çözücü kuşağı en az bir çıktı üretti;
  - hata (FAULT) yok.

  Hata nedenleri:
  - pes etme;
  - son çıktıdan bu yana en az 3 yapılandırma dışı kare çözücüye verildi, bunların en eskisi en az 1500 ms önce verildi ve hâlâ çıktı yok (T-028 sınıfı). Süre son çıktıdan değil, bekleyen en eski kareden ölçülür; böylece uzun süre durağan kalan ekranda çizime başlamak yanlış alarm vermez;
  - yüzey bağlandıktan 2 sn sonra çözücü iş parçacığı çalışmıyor, ya da eski kuşağın kapanma beklemesi zaman aşımına uğradı (M03).

  `VideoHealth` bu nedenleri tek bir genel `fault(cause)` girişiyle alır (`give_up|no_output|not_running|stuck`); çözücü bunları tek bir geri çağrıyla bildirir. T-161 yalnızca `stuck` nedenini ekler.

## Karar
Seçilen: **(c)**. Hata olunca:
- Yakalama kapanır. Bu, mevcut `RELEASE_ALL(USER)` dizisini gönderir, yani tel değişmez.
- Besleme ve keyframe yeniden denemeleri durur.
- "Görüntü durdu" katmanı gösterilir.
- Kurtarma şu sırayla yürür: 1 sn sonra çözücüyü yeniden başlat → 3 sn sonra yeniden başlat → oturumu yeniden kur → "Yeniden dene" düğmesi.

Kuşak, bir `attachSurface`/`reconfigure` çağrısıdır (yeni yapılandırma ya da yeni yüzey). Yeni kuşak ilk çözülmüş çıktısına kadar STARTING durumundadır ve girdi kapalıdır (olağan bırakmalarla). Yeniden bağlanma (yüzey yeniden bağlanır) ve göç (yeni STREAM_CONFIG → `reconfigure`) bu yolla kapsanır; oturumun kare sayacına dayanılmaz. Aynı bağlanma içinde `decode_error` sonrası çözücünün yeniden başlatılması yeni kuşak değildir: girdi açık kalır, yalnızca hata kuralları geçerlidir. Zamanlama çözücü **çıktısına** göre ölçülür (`dequeueOutputBuffer`), `onFrameRendered`'a göre değil. Durağan ekran (kare gelmiyor) hiçbir zaman hata sayılmaz.

**Kullanıcı 2026-10-03'te onayladı** (aşağıdaki üç madde; eşikler T-164 aygıt koşusundan sonra ayarlanabilir). Onaylananlar:
1. Görüntü donunca girdinin kendiliğinden kapanması ve tuşların bırakılması.
2. Eşikler: 1500 ms / 3 kare / 2 sn. Bunlar T-164 aygıt koşusundan sonra ayarlanabilir.
3. Kurtarma sırası.

## Sonuçlar
- **Kazanılan:** donmuş ya da siyah görüntüde girdi asla canlı kalmaz. Hata görünür olur ve sınırlı adımlarda kendiliğinden düzelir. Saniyede ~2 IDR döngüsü durur.
- **Kaybedilen:**
  - Yeniden bağlanmada girdi, ilk kare çözülene kadar kapalı kalır (yaklaşık bir kare süresi).
  - Her mod değişikliği ve yüzey yeniden bağlanması girdiyi kısa süre kapatır; o anda tutulan tuşlar ve kalem bırakılır.
  - Sunumu kısan panellerde yanlış alarm riski var. Bu yüzden ölçüm çıktıya bağlıdır.
- **Kapıladığı kartlar:** T-159 (sağlık kapısı) ve T-161 (çözücü kapanışına süre sınırı; "takıldı" hatasını `VideoHealth` üzerinden bildirir). Ön koşul T-158 (`DecoderCodec` arayüzü, karar gerektirmez). Aygıt kanıtı T-164. Hata enjeksiyonu (debug) açılışta kurulur ama görüntü N sn HEALTHY kaldıktan sonra tetiklenir; yoksa girdi hiç açılmadan hata oluşur ve tutulan tuş/kalem sınanamaz.
- **PROTOCOL.md:** değişmez. `RELEASE_ALL.reason = USER` yeniden kullanılır. PROTOCOL §4 nedeni zaten bilgi amaçlı sayıyor. Ayrı bir `VIDEO_FAULT` nedeni gerekmez; istenirse ayrı bir protokol kararı olur.
- **Tekrar düşünülür:** aygıtta yanlış alarm görülürse (eşikler), ya da host da çözücü sağlığına tepki vermeli denirse (`STATS.framesDecoded`).

**Uygulama notu (2026-10-03, T-159):** hata kuralları yeni kuşak STARTING'deyken de uygulanır; bağlanırken siyah kalan ekran da "Görüntü durdu" katmanını ve kurtarmayı alır. Kurtarma sırası: +1 sn decoder yeniden başlatma, +3 sn yeniden başlatma, +6 sn oturumu yeniden kurma, +15 sn "Yeniden dene" düğmesi. Bilinen boşluk: yalnız 1–2 kare alıp hiç çıktı vermeyen bir kuşak, `no_output` kuralı 3 kare istediği için STARTING'de kalır (input kapalı, katman yok).
