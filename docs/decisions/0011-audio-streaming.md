# 0011 — Ses aktarımı: Core Audio process tap, sıkıştırmasız PCM, kontrol bağlantısı

- **Durum:** kabul
- **Tarih:** 2026-10-01

## Bağlam
Kullanıcı Mac sesinin tablette çalmasını istedi (PLAN Aşama 5). Kullanıcı kararı (2026-10-01): oturum açıkken ses **yalnızca tablette** çalsın, Mac hoparlörü sussun. Oturum bitince Mac sesi geri gelsin.

Araştırma (NOTES 2026-10-01 ~19:10):
- **Mac:** Core Audio process tap (macOS 14.2+, `CATapDescription` + `AudioHardwareCreateProcessTap` + özel aggregate cihaz + IOProc) sistem sesini 48 kHz stereo Float32 olarak veriyor. `muteBehavior = .mutedWhenTapped` tap okunduğu sürece yerel çıkışı susturuyor.
  - Okuyan süreç ölünce susturma da biter. Genel ve `.muted` bir tap ise süreç ölse bile kalıyor; bu yüzden kullanılmaz.
  - İzin: "Yalnızca Sistem Sesi Kaydı" (TCC). İzin istemi IOProc oluşturulurken çıkıyor ve çağrıyı bloke ediyor.
  - ScreenCaptureKit sesi yerel çıkışı susturamıyor (sistem sesini kısmak gerekir; çökmede Mac sessiz kalır). Reddedildi.
- **Tablet:** NDK'sız `AudioTrack` `PERFORMANCE_MODE_LOW_LATENCY`, 48 kHz s16 stereo. AAudio ve Oboe bu cihazda (MMAP beklenmiyor) kazanç getirmez.

## Karar
1. **Yakalama:** process tap, stereo genel, host'un kendi süreci hariç, `.mutedWhenTapped`, `isPrivate = true`, özel aggregate, ayrı yüksek öncelikli kuyrukta IOProc.
   - Tap ve aggregate tek bir Swift tipinde (`SystemAudioTap`) toplanır.
   - İzin istemi ana iş parçacığını ve video/girdi yolunu bloke etmemeli.
   - Açılışta adıyla sızmış tap'ler temizlenir.
2. **Biçim:** sıkıştırmasız PCM s16le, 48 kHz, 2 kanal, 10 ms paket (480 kare, 1920 B), ~1,5 Mbps. Kodek ve bağımlılık yok. Sıkıştırma (Opus/AAC) gerekirse ileride `format` alanıyla eklenir.
3. **Taşıma:** **kontrol bağlantısı**, şifreli (§9). Video bağlantısında büyük kareler (Wi-Fi'de 20+ ms) sesi bekletirdi. Kontrol bağlantısında H→C yönü boş; girdi C→H yönünde, ses onu bekletmez.
4. **Mesajlar** (PROTOCOL §4, yeni aralık `0x30–0x3F` ses):
   - `0x30 AUDIO_PREFS` (C→H): istemci ses istiyor mu.
   - `0x31 AUDIO_CONFIG` (H→C): akış başladı/durdu, biçim.
   - `0x32 AUDIO_FRAME` (H→C): PCM paketi, akıştaki örnek sırası ve host yakalama zamanı (video ile aynı saat).
   - HELLO `capabilities` bit8 `AUDIO_PCM`.
5. **Ne zaman çalar:** yalnızca ACCEPTED, şifreli bir oturumda, istemci `AUDIO_PCM` bildirmiş ve `AUDIO_PREFS.enabled = 1` göndermişse. `enabled = 0`, BYE, bağlantı kopması ya da oturum sonu → host tap'i **hemen** kapatır (grace süresi beklenmez); Mac sesi geri gelir.
6. **Kuyruklar:**
   - Host bekleyen sesi en çok 100 ms tutar, taşarsa en eskiyi atar (`sample_index` boşluğu).
   - İstemci titreşim tamponu en çok 300 ms.
   - Ses video sunumunu asla geciktirmez. Ses biraz geç kalabilir (hedef ≤ 40 ms geç, ≤ 10 ms erken).
7. **Gizlilik:** ses içeriği asla loglanmaz ve kaydedilmez. Yalnızca sayaçlar loglanır (paket, düşen, seviye tabanı, alt taşma).

## Sonuçlar
- Kod: host'ta `SystemAudioTap` + `AudioStreamer`; tablette `AudioJitterBuffer`, `DriftController` (Hermite yeniden örnekleme ±%0,1–0,5), `AudioPlayout` (AudioTrack + yazıcı iş parçacığı).
- Host Info.plist'e `NSAudioCaptureUsageDescription` eklenir. Kullanıcı bir kez izin verir.
- Ses saatleri arasındaki kayma (~50 ppm) yeniden örneklemeyle emilir.
- Bluetooth kulaklıkta gecikme 150–250 ms'ye çıkar; kabul edilir.
- Kontrol bağlantısı Network.framework (`ch`) üzerinde. Wi-Fi'de kayıp ses kesintisi yaparsa kontrol bağlantısı da BSD soketine taşınır (T-091 deneyimi).
