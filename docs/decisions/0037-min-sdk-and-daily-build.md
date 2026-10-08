# 0037 — İstemci minSdk 31 ve günlük kullanım için debug olmayan derleme

- **Durum:** kabul (2026-10-08)
- **Tarih:** 2026-10-08

## Bağlam

T-297/T-298 ortak ayıklaması (`docs/reviews/2026-10-08/simplification.md`).

- **Debug APK:** tabletteki günlük APK `app-debug.apk`. `build.gradle.kts`'te `buildTypes` yok, yani ART debuggable modda çalışıyor ve yerel kod -O0 derleniyor. T-282 profilinde `roundToInt` yorumlayıcıya düşmüştü; bu debuggable ART'ın tipik belirtisi.
- **minSdk:** 29. Tek cihaz (MatePad Pro 12.2, HarmonyOS 4.3) API 31; API 29/30 dalları ölü kod.

## Seçenekler

- (a) Olduğu gibi kalsın.
- (b) Günlük kullanım için debug olmayan, `profileable` bir derleme, aynı imzayla yerinde güncelleme; debug APK tanı oturumları için kalır. minSdk 31.

## Karar

Seçilen: **(b)**. Kullanıcı onayı: 2026-10-08.

- **Yeni derleme türü:** `isDebuggable = false`, manifestte `<profileable android:shell="true"/>`, yerel kod Release/RelWithDebInfo.
  - Debug anahtarıyla imzalanır, böylece yerinde güncellenir ve eşleşme anahtarları korunur.
  - `scripts/install-apk.sh` varsayılan olarak bunu kurar; tanı için debug APK seçilebilir.
- **minSdk = 31.** API 29/30 dalları sadeleştirme partisinde silinir.
- **`--ez dev true` anahtarları** debug olmayan derlemede de çalışır. Yalnız `decoder_fault` `FLAG_DEBUGGABLE` ister.

## Sonuçlar

- **Kazanılan:** tahminen 60 fps'te tek çekirdeğin %5–10'u ve daha az titreşim. T-296 tabanına karşı ölçülür.
- **Kaybedilen:** debug olmayan APK'da `run-as` yok. Tercih yazma, dosya çekme ve `/proc` ayrıntıları için debug APK kurulur (`install-apk.sh` seçeneği).
