# 0012 — Tablette ses çıkışı için AAudio MMAP (NDK + C++)

- **Durum:** kabul
- **Tarih:** 2026-10-01

## Bağlam
Karar 0011'deki ses yolunda tablet `AudioTrack` kullanıyor. Cihazda yalnızca 20 ms'lik MIXER çıkışı var (FastMixer yok), bu yüzden AudioTrack çıkış gecikmesi ~99 ms. Uçtan uca ses ~170–190 ms; video ~51 ms.

T-099 sondası (NOTES 2026-10-01 ~21:50):
- AAudio `LOW_LATENCY` + `EXCLUSIVE` MMAP yolu cihazda var.
- Çıkış gecikmesi **~13 ms**, burst 240 kare (5 ms), xrun 0.
- Kazanç ~86 ms.

Kullanıcı onayı (2026-10-01): NDK kurulup ölçüldü, sonra "evet, AAudio MMAP'i ekle".

## Karar
1. İstemciye NDK ile küçük bir C++ katmanı eklenir (`client-android/app/src/main/cpp/`, CMake). Yalnızca AAudio akışı açma, yazma, zaman damgası ve kapatma yapar. Ses mantığı (titreşim tamponu, kayma, rampa, A/V) Kotlin'de kalır.
2. Tercih sırası:
   - AAudio `LOW_LATENCY` + `EXCLUSIVE`;
   - açılamazsa ya da `isMMapUsed`/paylaşım beklenenden farklıysa AAudio `SHARED`, yalnız ölçülen gecikme makulse;
   - yoksa bugünkü `AudioTrack` yolu.
   - Deney anahtarı: `--es audio_out aaudio|track`.
3. Veri akışı:
   - AAudio veri geri çağrısı (gerçek zamanlı iş parçacığı) kullanılır, ya da bloklamayan `write` ile kendi yazıcı iş parçacığı. Seçim uygulama kartının Plan'ında yapılır.
   - Geri çağrı kullanılırsa içinde tahsis, kilit, JNI yukarı çağrısı ve log yok. PCM, önceden ayrılmış ve kilitsiz bir halkadan okunur.
4. Hata ve yeniden kurulum: `AAUDIO_ERROR_DISCONNECTED` (yönlendirme değişimi, kulaklık) → akış yeniden açılır. Başarısızlık oturumu düşürmez.
5. Derleme:
   - NDK ve CMake sürümleri `build.gradle.kts`'te sabitlenir (NDK 30.0.16248370, CMake 4.1.2; T-099 ile kurulanlar).
   - `scripts/check.sh` bu araç setini gerektirir. `README`/`AGENTS` notu eklenir.
   - Yeni bir üçüncü taraf kütüphane yok; Oboe kullanılmaz.

## Ek (2026-10-01, T-100 incelemesi)
- Madde 3 netleşti: ayrı yazıcı iş parçacığından zaman aşımlı (200 ms; akışın ilk ~0,5 s'sinde 1 s) bloklayan AAudio `write` kabul edildi. Zaman aşımı yalnızca MMAP akışlarında güvenilir; bu yüzden **MMAP olmayan AAudio akışı hiç kullanılmaz** (`mmap != 1` → AudioTrack).

## Ek (2026-10-27, T-381 cihaz sonucu → T-382)
- Gerekçe: exclusive MMAP akışı ~8 dk sonra cızırdamaya başlıyordu (NOTES 2026-10-25 23:40). Shared MMAP 42 dk temiz çaldı; gecikme farkı hissedilmedi (NOTES 2026-10-26 18:15). Kullanıcı onayı (2026-10-27): shared varsayılan olsun, eski ayara panelden tek tuşla dönülebilsin.
- Madde 2'deki tercih sırası değişir. Panel "Ses çıkışı" üç seçenekli olur:
  - **Düşük gecikme** (kayıtlı `auto`, varsayılan): AAudio `SHARED` MMAP → `AudioTrack`. EXCLUSIVE denenmez, gecikme denetimi (probation) yok (T-381'de ölçülen yol).
  - **Düşük gecikme (eski)** (kayıtlı `exclusive`): bu ekten önceki `auto` zinciri, birebir: EXCLUSIVE → SHARED (probation'lı) → `AudioTrack`.
  - **Uyumlu** (kayıtlı `track`): değişmez.
- MMAP olmayan AAudio akışı yine hiç kullanılmaz (2026-10-01 eki).
- Kayıtlı `auto` olan mevcut kurulumlar yeni varsayılana geçer; geçiş kodu gerekmez.

## Sonuçlar
- Ses gecikmesi tahminen ~90–100 ms'ye iner; A/V farkı ~40–50 ms.
- Proje artık C++ ve NDK araç seti gerektiriyor; yeni bir makinede kurulum adımı var.
- EXCLUSIVE akış açıkken tabletteki diğer uygulamaların sesi normal mikser yolundan çalmaya devam etmeli. Cihazda doğrulanacak; sorun çıkarsa `SHARED`'a ya da AudioTrack'e dönülür.
