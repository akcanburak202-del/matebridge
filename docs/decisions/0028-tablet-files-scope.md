# 0028 — Tablet dosya paylaşımı: seçilen klasör ve salt okunur seçeneği (0015'i değiştirir)

- **Durum:** kabul (2026-10-03)
- **Tarih:** 2026-10-03

## Bağlam
Kaynak: dış mimari incelemesi 2026-10-03 (HEAD a30c769), M05 (dosya kapsamı) ve D9. Doğrulama: `docs/reviews/2026-10-03/verify-A-security.md` (M05, A4, WI-6) ve `verify-A2-adversarial.md` §2.

Karar 0015 madde 1, WebDAV kökünü bütün paylaşılan depolama olarak belirledi:
- Kök `/sdcard`, `MANAGE_EXTERNAL_STORAGE` izniyle (`FilesController.kt:83-85`, `AndroidManifest.xml:8-11`).
- Klasör seçimi ve salt okunur kip yok.

Sınırlar doğru çalışıyor:
- Sunucu yalnızca `127.0.0.1`'e bağlanıyor.
- Jeton her başlangıçta yeni üretiliyor (128 bit).
- Kanonik yol ve symlink denetimleri var (`DavPath.kt:107-185`).

Yine de onaylı Mac, ya da jetonu bir şekilde ele geçiren biri, bütün depolamayı okuyup yazabiliyor. H01 (0018) yüzünden jeton, sahte bir host'a ya da `127.0.0.1:47001`'i tutan yerel bir uygulamaya gidebiliyordu. Bu açığı 0018 kapatıyor. Kapsamı daraltmak ikinci bir savunma katmanı.

Sunucunun ömrü de kullanımdan geniş: uygulama ön plandayken ve ayar açıkken hep çalışıyor (`FilesController.kt:39-47`). Ömür ayrı bir kararla değil, T-153'te daraltılıyor: yalnızca kabul edilmiş ve güvenilir bir USB oturumu sırasında.

## Seçenekler
- **(a) Bütün paylaşılan depolama (bugün, 0015 madde 1).** En kullanışlısı, ama erişim kapsamı en geniş.
- **(b) Kullanıcının seçtiği klasör (önerilen).** Ayrıntılar:
  - Varsayılan klasör `Download/` ya da bir "MateBridge" klasörü.
  - İsteğe bağlı "tüm depolama" seçeneği.
  - İsteğe bağlı salt okunur kip: PUT, DELETE, MKCOL, MOVE, COPY ve LOCK 403 döner.
  - Seçilen kökün dışına yol, kodlama ya da symlink ile kaçış reddedilir.
- **(c) SAF/DocumentsProvider ile yeniden yazım.** Daha "Android'e uygun", ama büyük iş ve Finder WebDAV akışını değiştirmez. Bu kararın kapsamı dışında.

## Karar
Seçilen: **(b)**. 0015 madde 1'in yerini alır. 0015'in geri kalanı aynı kalır:
- yalnızca USB tüneli;
- jetonla kimlik doğrulama;
- `FILES_INFO`;
- aktarım hızı tavanı.

`MANAGE_EXTERNAL_STORAGE` alt klasöre yol ile erişim için hâlâ gerekli. `FILES_INFO` değişmez.

**Kullanıcı 2026-10-03'te onayladı:**
- Varsayılan kök ayrı bir **MateBridge klasörü** (`/sdcard/MateBridge/`, yoksa oluşturulur); `Download/` değil.
- "Tüm depolama" seçeneği ayarlarda kalır.
- Salt okunur kip sunulur.

Sorulanlar (manifest §5 soru 7):
1. Varsayılan klasör ne olsun: `Download/` mı, ayrı bir "MateBridge" klasörü mü?
2. "Tüm depolama" seçeneği kalsın mı?
3. Salt okunur kip sunulsun mu?

## Sonuçlar
- **Kazanılan:** onaylı Mac yalnızca kullanıcının seçtiği klasöre ulaşır. Jeton bir gün yine sızarsa zarar sınırlı kalır.
- **Kaybedilen:** başka klasördeki dosyalar için önce kökü değiştirmek ya da "tüm depolama"yı seçmek gerekir.
- **Kapıladığı kart:** T-190 (paylaşılan klasör kapsamı). T-153'ten (sunucu ömrü) sonra gelir. T-153, 0018'e bağlı ve bu kararı beklemez.
- **Mevcut kararlar:** 0015 madde 1'in yerini alır. 0015'in durum satırına "madde 1'in yerini aldı: 0028" notu eklenir.
- **PROTOCOL.md:** değişmez. `FILES_INFO` (0x09) ve fixture'lar aynı kalır. Sunucunun başlama ve durma zamanı §4 0x09'un zaten izin verdiği aralıkta.
- **Tekrar düşünülür:**
  - Wi-Fi üzerinden dosya erişimi istenirse (TLS gerekir; 0015'te de not edildi);
  - birden fazla klasör ya da cihaz başına farklı kök istenirse.
