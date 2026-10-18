---
id: T-355
title: İstemci — tablet kamerası: panel ayarı, Camera2 → H.264, kamera bağlantısı
status: done
phase: 7
owner: android-client-dev
depends_on: []
decisions: [0040]
files:
  - client-android/app/src/main/
  - client-android/app/src/test/
  - docs/LOGGING.md
  - backlog/tasks/T-355-client-camera.md
---

## Amaç

Karar 0040 (ek 2026-10-18) ve PROTOCOL.md'deki kamera bölümü (dal `task/T-353-camera-protocol`, commit 5b1b9b49: 0x0E CAMERA_PREFS, 0x0F CAMERA_CONTROL, "Kamera bağlantısı", 0x60–0x63, bit15, §5 Kamera, §9 kamera anahtarları). Protokol orkestratörün; değişiklik gerekirse kodlama, Open questions'a yaz.

## Kapsam

1. **Kodek:** dört kamera bağlantısı mesajı + iki kontrol mesajı, Kotlin kodlama/çözme, bütün yeni fixture'lar ve `crypto_vectors.json` kamera anahtarları/kayıtları fixture testlerinde (mevcut kalıp). HELLO'da bit15 `CAMERA` (yalnız cihazda en az bir kamera ve H.264 kodlayıcı varsa).
2. **Ayarlar ve panel:** `camera_mode` (OFF varsayılan / AUTO) ve `camera_facing` (FRONT varsayılan / BACK) kalıcı ayarlar; panelde yeni bir "Kamera" bölümü ya da Görüntü sonrası: "Kamera: Kapalı / Otomatik" ve "Kamera yönü: Ön / Arka", altında küçük durum satırı: "Mac kamerayı kullanmıyor" / "Kamera açık" / "Mac'te OBS sanal kamera yok" (UNAVAILABLE) / "Kamera izni yok". Uzak oturumda gizli. "Varsayılanlara dön" kapatır. Not: T-352 paralel olarak panelin görünümünü yeniden tasarlıyor; sen yalnız `SettingsCatalog`'a mevcut öğe türleriyle (Choice/Info) öğe ekle, görünüm koduna dokunma.
3. **İzin:** Manifest'e `CAMERA`. Kullanıcı Otomatik'i ilk seçtiğinde çalışma zamanı izni istenir; reddedilirse ayar Kapalı'ya döner ve durum satırı "Kamera izni yok" der. İzin yokken `CAMERA_PREFS.mode = OFF` gider.
4. **CAMERA_PREFS:** ACCEPTED'dan sonra ve her değişiklikte (uzak oturumda hep OFF).
5. **CAMERA_CONTROL işleme:** START → `CameraStreamer` başlar: Camera2 (facing), `MediaCodec` H.264 yüzey girdili kodlayıcı (desteklenen en yakın 16:9 boyut, fps, bit hızı, I-frame aralığı 2 sn, düşük gecikme ayarları), kamera bağlantısı. Kare dik ve yatay gitmeli: sensör yönü ile ekran yönü farklıysa bir OpenGL ES geçişiyle döndür (Camera2 → SurfaceTexture → GL → kodlayıcı yüzeyi); ön kamerada ayna uygulama. STOP / UNAVAILABLE / oturum sonu / onStop / ayar OFF → hemen her şeyi kapat (kamera, kodlayıcı, GL, soket, thread'ler). Ön plana dönünce hâlâ START ise yeniden aç (aynı cam_id). Akış sırasında facing değişirse kamerayı değiştir, aynı bağlantıda yeni CODEC_CONFIG + keyframe.
6. **Kamera bağlantısı:** PROTOCOL'deki 9 madde: CAM_HELLO → CAM_HELLO_ACK (5 sn), iki nonce ile anahtarlar (§9), ilk şifreli kayıt PING, sonra CODEC_CONFIG + keyframe + kareler; `CAM_KEYFRAME_REQUEST` → bir sonraki kare keyframe (MediaCodec `PARAMETER_KEY_REQUEST_SYNC_FRAME`) + önünde CODEC_CONFIG; kopmada 1 sn arayla en çok 3 yeniden deneme; sonra kamerayı kapat. Gönderim kuyruğu ≤ 2 kare (§5), taşınca keyframe olmayanları at + keyframe iste. Mevcut dosya/video bağlantısı kodundaki kalıpları yeniden kullan.
7. **Sıfır maliyet:** mode OFF ya da START gelmemişken hiçbir kamera/kodlayıcı/GL/soket/thread yok (test).
8. **Gizlilik ve log:** kare içeriği loglanmaz/yazılmaz. `docs/LOGGING.md` biçiminde: `ev=camera state=start|stop reason= cam_id= size= fps=`, 10 sn özet (kodlanan, gönderilen, düşen kare, ortalama kare boyutu). Girdi ve ekran akışı yolları değişmez.

## Kabul

- Fixture ve kripto testleri (Kotlin) yeşil. Birim testleri: CAMERA_PREFS üretimi (uzakta OFF, izin yokken OFF), CAMERA_CONTROL durum makinesi (START/STOP/UNAVAILABLE, aynı cam_id tekrarı, yeni cam_id, onStop/onStart, oturum sonu), kamera bağlantısı el sıkışma ve kanıt sırası, kuyruk taşması, keyframe isteği. Camera2/MediaCodec/GL arabirim arkasında, testte sahte.
- `./scripts/check.sh` Android kısmı geçer (host paralel kartta, T-354). Başka bir ajan aynı anda Gradle çalıştırıyorsa ve derleme dizini çakışırsa bekleyip yeniden çalıştır.
- Cihaz testi orkestratörde. Tablete dokunma.

## Plan

1. Kodek: `CameraPrefs`, `CameraControl`, `CamHello`, `CamHelloAck`, `CamFrame`, `CamKeyframeRequest` + `Capabilities.CAMERA` (bit15); `KeySchedule.cameraC2h/H2c`, `SessionSecrets.cameraKeys`, `CameraChannel`; fixture ve kripto testleri.
2. Saf mantik (`camera/`): `CameraWish`/`CameraPrefsPolicy` (uzakta ve izinsizken OFF), `CameraMath` (donus, GL matrisi, boyut/fps secimi), `CamSendQueue` (<=2 kare, keyframe kapisi, config onde), `CameraConnection` (el sikisma, kanit PING, yazici/okuyucu), `CameraStreamer` (3 yeniden deneme, istatistik), `CameraController` (CAMERA_CONTROL durum makinesi).
3. Android: `Camera2Pipeline` (Camera2 -> SurfaceTexture -> `GlEncoderSurface` -> H.264 MediaCodec yuzey girdisi), `AndroidCameraRunFactory`.
4. Oturum: `SessionMachine` (`SetCamera`, CAMERA_PREFS kabulden sonra, `CameraControlReceived`), `SessionController` (oturum sonunda `camera.onSessionEnd()`), `MainActivity` (izin istemi, onStart/onStop, HELLO bit15, ayarlar), `Settings` + `SettingsCatalog` ("Kamera" bolumu, yalniz Choice/Info).

## Handoff

- **Commit:** e2fe8582 (dal `task/T-355-client-camera`, T-353 tabanli 76c877a8). `./scripts/check.sh --only android` gecti (2373 test). Not: `DecoderWaitTest.inputParksWithFewWakeUps...` ve `OutputParkTest.withParkOff...` gercek zamanli poll sayan testler; makine yukluyken (baska ajanin Gradle'i) tutarli kirildi, bos kosuda ve T-353 tabaninda gecer; kamera koduyla ilgisi yok.
- **Dokunulan dosyalar:** `protocol/{Messages,Codec}.kt`, `security/{Crypto,Handshake}.kt` (kamera anahtarlari, `CameraChannel`), yeni `camera/` paketi (`CameraWish`, `CameraMath`, `CamSendQueue`, `CameraConnection`, `CameraStreamer`, `CameraController`, `Camera2Pipeline`, `GlEncoderSurface`, `AndroidCameraRunFactory`), `session/{SessionMachine,SessionController,Latest,Settings}.kt`, `settings/SettingsCatalog.kt` ("Kamera" bolumu, yalniz Choice/Info; gorunum kodu yok), `MainActivity.kt` (kucuk, yerel bloklar), `AndroidManifest.xml` (CAMERA izni, `uses-feature required=false`), testler, `docs/LOGGING.md` ("Tablet kamerasi" bolumu, `camera` bileseni).
- **Dondurme yaklasimi:** GL gecisi. Camera2 -> `SurfaceTexture` (OES doku) -> `GlEncoderSurface` (EGL, `EGL_RECORDABLE_ANDROID`) -> kodlayici giris yuzeyi. Dondurme dereceleri `CameraMath.rotationDegrees` (CameraX bagintisi: arka = sensor - ekran, on = sensor + ekran; ekran = `defaultDisplay.rotation`, her karede okunur, `sensorLandscape` ters yatay donusunde de dik kalir). `CameraMath.mvp` kaynak tamponu saat yonunde dondurup 16:9 cikisa "cover" (merkez kirpma) olcekler; SurfaceTexture doku matrisi ayrica uygulanir. On kamerada ayna YOK (PROTOCOL 0x0F: Mac uygulamalari kendi onizlemesini aynalar; kart "ayna uygulama" der, uyumlu). Birim testli: donus tablosu, kose esleme, kirpma.
- **Kodlayici:** `video/avc`, yuzey girdisi, CBR (destekliyse), 2 sn I-frame, `KEY_LATENCY=1`, `KEY_PRIORITY=0`, B-frame yok; profil High -> Main -> varsayilan sirasiyla denenir (configure hatasinda yeni kodlayici). Boyut: istenen yoksa 16:9 merdiven (1920x1080 ... 640x360). SPS/PPS hem CODEC_CONFIG tamponundan hem `csd-0/1`'den alinir, ayni bayt bir kez gonderilir. Keyframe istegi `PARAMETER_KEY_REQUEST_SYNC_FRAME`.
- **Kamera baglantisi:** PROTOCOL "Kamera baglantisi" 9 madde: CAM_HELLO -> CAM_HELLO_ACK (5 sn) -> anahtarlar (iki nonce) -> ilk sifreli kayit PING -> CODEC_CONFIG (seq 0) + keyframe + kareler. Kuyruk <= 2 kare; tasinca bekleyen keyframe olmayanlar atilir, keyframe gelene kadar delta atilir ve kodlayicidan keyframe istenir. Kopmada ayni cam_id ile 1 sn arayla en cok 3 deneme (>= 5 sn ayakta kalan baglanti sayaci sifirlar); REJECTED sonlandiricidir (yeniden denenmez). Yazma 5 sn ilerlemezse `WriteWatchdog` soketi kapatir.
- **Sifir maliyet:** `CameraController` is parcacigi/nesne yaratmaz; `CameraRunFactory` yalniz mod AUTO + izin + on plan + START varken cagrilir (testli). Kamera/kodlayici/GL/soket/is parcaciklari `CameraRun.close` ile hemen gider: STOP, UNAVAILABLE, yeni cam_id, oturum sonu (BYE, kayip, goc), `onStop`, ayar OFF, izin kaybi. Ayni cam_id START'i bir sey degistirmez; onStart'ta tutulan START ayni cam_id ile yeniden acilir.
- **Varsayimlar:** (1) USB oturumda kamera baglantisi `ep.host:CAMERA_CONTROL.port`'a gider; `adb reverse` ile o portun yonlendirilmesi host/orkestrator isidir (kod bunu yapmaz). (2) Kamera baglantisi disi bir acilista `ack_timeout`/`io` yeniden denenir; `rejected` ve anahtar silinmesi (`keys_gone`) denenmez. (3) Izin reddi: ayar Kapali'ya doner, durum satiri "Kamera izni yok" (Varsayilanlara don veya yeniden Otomatik secmek bayragi temizler). (4) Kamera onPause'ta (ornegin izin penceresi) kapanmaz, yalniz onStop'ta; sistem kamerayi elinden alirsa (`onDisconnected`) akis biter ve yeni START beklenir.
- **TEST EDILMEDI (cihaz gerekir):** gercek Camera2/MediaCodec/GL yolu hic calistirilmadi (JVM'de sahte arayuzle test edildi); Huawei kodlayicisinin profil/CBR/`KEY_LATENCY` kabulu; donusun gercek tablette dik cikmasi (arka/on, iki yatay yon); izin istemi akisi; HarmonyOS'ta kamera cakismasi.

### Tablette / Mac'te denenecek (orkestrator)

1. Ayarlar -> "Kamera" bolumu gorunur (Kapali varsayilan, Yon: On). Otomatik'e dokun: izin penceresi cikar; reddet -> ayar Kapali'ya doner, satir "Kamera izni yok"; izin ver -> "Mac kamerayi kullanmiyor". Uzak oturumda satirlar gizli, "Uzak oturumda kamera kapali."
2. Mac'te (T-354 host) OBS sanal kamerasini bir uygulamada (Photo Booth) ac: `adb logcat -s MB/camera` -> `camera_control_recv state=1`, `state=start`, `state=encoder size=1920x1080`, `link_up`, 10 sn'de bir `camera_stats`. Mac'te goruntu DIK ve YATAY olmali (tableti iki yatay yone cevir, ters yatay da dahil); On kamerada Mac uygulamasinin kendi onizleme aynasi disinda ek ayna olmamali.
3. Yon: Arka/On degistir -> ayni baglantida goruntu degisir (yeni `link` acilmaz, `state=switch`); Mac tarafinda donma/bozulma olmamali (yeni CODEC_CONFIG + keyframe).
4. Kapanis: Mac uygulamasinda kamerayi birak -> `STOP` -> `camera state=stop reason=stop` ve tabletin kamera isigi soner; Home'a bas (onStop) -> aninda `reason=background`, geri gel -> ayni cam_id ile yeniden acilir; Kamera: Kapali sec -> aninda `mode_off`; BYE/Mac uykusu -> `session_end`. Kamera kapaliyken `adb shell dumpsys media.camera` kullanim yok, kod yolunda `mb-cam*` is parcacigi yok.
5. Ag kopmasi: Mac'te kamera dinleyicisini kapat/ac veya Wi-Fi'yi kes -> `link_down`, `retry n=1..3` (1 sn arayla), sonra `stop reason=link_lost`. USB'de `adb reverse` ile kamera portu yonlendirilmeden baglanti `io` ile 3 kez denenip kapanir (beklenen).

## Open questions

- Kamera USB oturumunda: `CAMERA_CONTROL.port` Mac'in dinleyicisidir ve loopback uzerinden ancak `adb reverse tcp:<port>` ile ulasilir; PROTOCOL bunu soylemiyor (dosya baglantisi USB'de kullanilmaz). Orkestrator/host karti (T-354) karar vermeli: sabit port 47004 icin `adb reverse` ya da kamera yalniz Wi-Fi.
- Kamera onPause'ta degil onStop'ta kapanir (kart: onStop). Android 11+ kamerayi on planda olmayan uygulamadan zaten keser; bu durumda akis `camera_disconnected` ile biter ve bir sonraki START'a kadar acilmaz.
