# 0040 — Tablet kamerasını Mac'te webcam yapmak: OBS sanal kamerası (deneme)

- **Durum:** önerildi (2026-10-17; deneme T-351 sonucuna bağlı)
- **Tarih:** 2026-10-17

## Bağlam

Kullanıcı tabletin ön ve arka kamerasını Mac'te laptop kamerası gibi kullanmak istiyor (Zoom, FaceTime, Meet). macOS'ta sistem kamerası iki yolla sunulur:
- CoreMediaIO Camera Extension: sistem uzantısı izni ve notarizasyon ister, ücretli Apple Developer hesabı gerekir. Kullanıcının hesabı yok.
- Eski DAL eklentileri: macOS 14'ten beri yüklenmiyor.

Araştırma (2026-10-17): imzalı ve ücretsiz OBS Studio'nun kamera uzantısı bir "sink" akışı sunuyor. OBS'in kendi eklentisi bu akışa `CMIOStreamCopyBufferQueue` ve `CMSimpleQueueEnqueue` ile kare yazıyor. Başka bir sürecin aynısını yapıp yapamayacağı denenmedi.

## Karar

- **Bağımlılık:** OBS Studio (GPLv2) Mac'e kullanıcı tarafından ayrı bir uygulama olarak kurulur. MateBridge ona bağlanmaz (link yok), yalnız sistem CoreMediaIO API'si ile OBS sanal kamera cihazının sink akışına kare yazar. OBS'in kodu projeye girmez.
- **Önce deneme (T-351):** host tarafında bağımsız bir Swift aracı OBS sink akışına test deseni yazar. Kullanıcı FaceTime/Photo Booth'ta görüntüyü görürse yol açıktır.
- Deneme başarılıysa tasarım ayrı bir kararla gelir: protokolde kamera kanalı (tablet → Mac H.264), tablette Camera2 (ön/arka seçimi), panelde **varsayılan kapalı** "Kamera" anahtarı. Kamera kapalıyken hiçbir iş parçacığı, codec ya da ağ trafiği olmaz, akış performansı etkilenmez.
- Deneme başarısızsa yedek: OBS'in medya kaynağı MateBridge'in yerel ağda yayınladığı akışı okur (daha yüksek gecikme).

## Sonuçlar

- Ücretli hesap gerekmez. Kullanıcı OBS'i bir kez kurar ve kamera uzantısını Sistem Ayarları'ndan onaylar.
- OBS sürüm değişiklikleri sink yolunu bozabilir. Bu özel bir arabirimdir, OBS'in desteklediği bir API değildir.
- macOS 27'de OBS sanal kamerası için "system process not found" raporu var; düzeltmesi uzantıyı kaldırıp yeniden kurmak.
