---
id: T-355
title: İstemci — tablet kamerası: panel ayarı, Camera2 → H.264, kamera bağlantısı
status: todo
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

## Handoff

## Open questions
