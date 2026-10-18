# 0040 — Tablet kamerasını Mac'te webcam yapmak: OBS sanal kamerası

- **Durum:** kabul (2026-10-18; T-351 denemesi başarılı, tasarım kullanıcı onaylı)
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

## Ek (2026-10-18): tasarım (kullanıcı onaylı)

- **Panel:** "Kamera: Kapalı / Otomatik" (varsayılan **Kapalı**) ve "Ön / Arka". Otomatik: tablet kamerası yalnız Mac'te bir uygulama sanal kamerayı kullanırken açık. Uzak oturumda kamera yok.
- **Protokol:** `CAMERA_PREFS` (0x0E, C→H), `CAMERA_CONTROL` (0x0F, H→C), ayrı şifreli kamera bağlantısı (`CAM_HELLO`/`CAM_HELLO_ACK`/`CAM_FRAME`/`CAM_KEYFRAME_REQUEST`, 0x60–0x63; dosya bağlantısı el sıkışma kalıbı), capability bit15 `CAMERA`. Ayrıntı PROTOCOL.md.
- **Tablet:** Camera2 → MediaCodec H.264 (öneri 1920×1080, 30 fps, 6 Mbps), dik/yatay, aynasız.
- **Mac:** VideoToolbox çözme → OBS sanal kamera sink akışı (`kCMIOStreamPropertyDirection = 0` olan akış, T-351). Kullanım algılama host'un işi.
- Kapalıyken iki tarafta da sıfır iş.
- **Yeniden düşünme:** OBS sink yolu bir sürümde bozulursa; ya da kullanıcı ücretli hesap alırsa kendi CMIO uzantımız.

## Ek 2 (2026-10-18): kullanım bitişi ve "Kamerayı şimdi kapat" (kullanıcı kararı C)

- Ölçüm (T-354 `--watch`): host yazmıyorken OBS cihazının `IsRunningSomewhere` özelliği uygulamanın açışını ve kapanışını anında gösteriyor. Host yazarken kendi yazımı özelliği 1 tutuyor; uygulamanın kapanışında hiçbir özellik ya da dinleyici değişmiyor.
- Seçenekler: A) dakikada bir ~0,1 sn yazımı durdurup bakmak (görüşmede görünür takılma), B) hiç bakmamak (elle kapatma), C) B + boşta denetim. **Kullanıcı C'yi seçti:** görüşme sırasında periyodik denetim yok; Mac'te 10 dk girdi yoksa (boşta kaldıkça her 10 dk) ya da uyku/ekran uykusu öncesi kısa denetim; kullanım yoksa STOP.
- Panelde kamera açıkken **"Kamerayı şimdi kapat"**: `CAMERA_PREFS.release_seq` artar, host STOP gönderir ve uygulama kamerayı bırakıp yeniden açana kadar başlatmaz. "Kapalı" seçeneği de durur.
