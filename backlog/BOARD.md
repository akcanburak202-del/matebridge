# Board

_Otomatik üretildi: `./scripts/board.sh` — elle düzenleme._

## blocked

| ID | Başlık | Aşama | Sahip | Bağımlılık |
|---|---|---|---|---|
| [T-019](tasks/T-019-gl-jitter-wifilock.md) | Akıcılık — GL yolunda titreşim tamponu ve Wi-Fi düşük gecikme kilidi | 1 | android-client-dev | [T-018] |
| [T-067](tasks/T-067-client-lock-recenter.md) | Tablet — faz kilidi geç kare oranına göre yeniden ortalanır; boşta kalınca jitter geçmişi silinmez | 5 | android-client-dev | [T-065] |

## done

| ID | Başlık | Aşama | Sahip | Bağımlılık |
|---|---|---|---|---|
| [T-001](tasks/T-001-repo-bootstrap.md) | Repo iskeletini kur ve GitHub'a yayınla | 0 | orchestrator | [] |
| [T-002](tasks/T-002-toolchain-and-tablet-setup.md) | Geliştirme araçlarını ve tableti hazırla | 0 | user | [] |
| [T-003](tasks/T-003-android-input-probe.md) | Android girdi probu — kalem, klavye, trackpad olaylarını kaydet | 0 | android-client-dev | [T-002] |
| [T-004](tasks/T-004-mac-vdisplay-probe.md) | Mac sanal ekran probu — 2800×1840 sanal ekran oluştur ve yakala | 0 | mac-host-dev | [] |
| [T-005](tasks/T-005-mac-pen-sink-probe.md) | Mac kalem alıcı probu — sentetik tablet olayları enjekte et ve doğrula | 0 | mac-host-dev | [] |
| [T-006](tasks/T-006-signing-identity.md) | Sabit imza kimliği (Apple Development) ve .app paketleme betiği | 0 | orchestrator | [] |
| [T-007](tasks/T-007-protocol-v0.md) | Protokol v0 taslağı ve altın örnekler | 0 | orchestrator | [T-003, T-004, T-005] |
| [T-008](tasks/T-008-host-skeleton-codec.md) | Mac iskeleti ve protokol kodeki (MateBridgeCore) — fixture testleriyle | 1 | mac-host-dev | [T-007] |
| [T-009](tasks/T-009-client-skeleton-codec.md) | Android iskeleti ve protokol kodeki — fixture testleriyle | 1 | android-client-dev | [T-007] |
| [T-010](tasks/T-010-host-session-server.md) | Mac oturum sunucusu — Bonjour, kontrol bağlantısı, onay, heartbeat | 1 | mac-host-dev | [T-008] |
| [T-011](tasks/T-011-host-video-pipeline.md) | Mac görüntü hattı — sanal ekran, yakalama, HEVC kodlama, sınırlı kuyruk | 1 | mac-host-dev | [T-008] |
| [T-012](tasks/T-012-client-session.md) | Android oturum istemcisi — NSD keşif, bağlantı, onay bekleme, heartbeat, yeniden bağlanma | 1 | android-client-dev | [T-009] |
| [T-013](tasks/T-013-client-video-decode.md) | Android görüntü çözme — MediaCodec HEVC düşük gecikme, SurfaceView, sınırlı kuyruk | 1 | android-client-dev | [T-009] |
| [T-014](tasks/T-014-host-integration.md) | Mac entegrasyonu — oturum + görüntü hattı, istatistik, uçtan uca akış | 1 | mac-host-dev | [T-010, T-011] |
| [T-015](tasks/T-015-client-integration.md) | Android entegrasyonu — oturum + görüntü, tam ekran, istatistik katmanı | 1 | android-client-dev | [T-012, T-013] |
| [T-016](tasks/T-016-video-smoothness.md) | Görüntü akıcılığı — kare zamanlaması, 120 Hz, titreşim ölçümü | 1 | android-client-dev | [T-015] |
| [T-017](tasks/T-017-host-frame-cadence.md) | Mac kare temposu — yakalama aralığı ölçümü, sanal ekran yenileme hızı, kayıp karelerin kaynağı | 1 | mac-host-dev | [T-014] |
| [T-018](tasks/T-018-client-gl-presentation.md) | Tablette sunum kontrolü — GL yolu (SurfaceTexture), vsync'e hizalı çizim, 120 Hz denemesi | 1 | android-client-dev | [T-016, T-017] |
| [T-020](tasks/T-020-host-fixed-ports-usb.md) | Mac — sabit varsayılan portlar ve USB modu betiği | 1 | mac-host-dev | [T-014] |
| [T-021](tasks/T-021-client-usb-connect.md) | Android — "USB ile bağlan" seçeneği | 1 | android-client-dev | [T-015] |
| [T-022](tasks/T-022-host-input-state.md) | Mac girdi durum makinesi — kalem, işaretçi, dokunma, release-all (saf, testli) | 2 | mac-host-dev | [T-014] |
| [T-023](tasks/T-023-host-input-injection.md) | Mac girdi enjeksiyonu — CGEvent kalem/fare, koordinat dönüşümü, oturuma bağlama | 2 | mac-host-dev | [T-022] |
| [T-024](tasks/T-024-client-pen-capture.md) | Tablet kalem ve dokunma yakalama — PEN toplu örnekler, POINTER_ABS, avuç reddi, RELEASE_ALL | 2 | android-client-dev | [T-015] |
| [T-025](tasks/T-025-phase2-device-validation.md) | Faz 2 cihaz doğrulaması — Krita test matrisi, kalem gecikmesi, takılı girdi avı | 2 | orchestrator | [T-023, T-024] |
| [T-026](tasks/T-026-client-pen-unbuffered.md) | Tablet — kalem örneklerini bekletmeden ilet (unbuffered dispatch), yinelenen örnek sayacı | 2 | android-client-dev | [T-024] |
| [T-027](tasks/T-027-krita-eraser-switch.md) | Çift dokunma Krita'da fırça değiştirmiyor — nedenini bul, karar 0006'yı doğrula ya da değiştir | 2 | orchestrator | [T-023] |
| [T-028](tasks/T-028-black-screen-on-display-reuse.md) | Hızlı yeniden bağlanmada siyah ekran — sanal ekran yeniden kullanılınca tablet hiç kare çözmüyor | 2 | orchestrator | [T-014, T-015] |
| [T-029](tasks/T-029-client-pen-contact-confirm.md) | Tablet — tek örneklik kalem temasını iletme (temas doğrulama), Krita'daki "diken"in tetikleyicisi | 2 | android-client-dev | [T-026] |
| [T-030](tasks/T-030-host-config-with-startup-keyframe.md) | Mac — STARTUP/DECODE_ERROR keyframe isteğinde CODEC_CONFIG'i yeniden gönder (hızlı yeniden bağlanmada siyah ekran) | 2 | mac-host-dev | [T-014] |
| [T-031](tasks/T-031-host-tablet-device-identity.md) | Mac — kalem yakınlık olayında cihaz kimliği (vendorPointerType, uniqueID); Krita kalemi fare sanıyor | 2 | mac-host-dev | [T-023] |
| [T-032](tasks/T-032-host-keyboard.md) | Mac klavye — KEY → macOS keycode, değiştiriciler, otomatik tekrar, Caps Lock, release-all | 3 | mac-host-dev | [T-023] |
| [T-033](tasks/T-033-client-keyboard.md) | Tablet klavye — fiziksel tuşları KEY olarak gönder, Android'e bırakma, sökülünce bırak | 3 | android-client-dev | [T-024] |
| [T-034](tasks/T-034-client-trackpad-mouse.md) | Tablet trackpad ve fare — pointer capture, POINTER_REL, dokunarak tık, iki parmak kaydırma/sağ tık | 3 | android-client-dev | [T-033] |
| [T-035](tasks/T-035-client-pointer-speed-exit.md) | Tablet — imleç hızı (daha yavaş varsayılan + canlı ayar kısayolu), Android'e dönüş kısayolu | 3 | android-client-dev | [T-033, T-034] |
| [T-036](tasks/T-036-host-pinch.md) | Mac — PINCH kodeki, yakınlaştırma durum makinesi ve büyütme hareketi enjeksiyonu | 3 | mac-host-dev | [T-032] |
| [T-037](tasks/T-037-client-pinch.md) | Tablet — iki parmakla yakınlaştırma (dokunmatik ekran ve touchpad) → PINCH | 3 | android-client-dev | [T-034, T-035] |
| [T-038](tasks/T-038-client-shortcuts-no-fkeys.md) | Tablet — F tuşu olmayan klavye için yerel kısayollar (Ctrl+Shift+8/9/0) | 3 | android-client-dev | [T-035] |
| [T-039](tasks/T-039-host-daily-use.md) | Mac günlük kullanım — oturum açılışında başlama, menü (durum, loglar), USB tünellerini kendiliğinden kurma | 4 | mac-host-dev | [T-020] |
| [T-040](tasks/T-040-host-lock-screen.md) | Mac — ekran kilidi ve ekran uykusu açıkken çalışma (kilit ekranında görüntü + şifre yazma, girdiyle uyanma) | 4 | mac-host-dev | [T-039] |
| [T-041](tasks/T-041-host-encryption.md) | Mac — protokol v1 şifreleme (el sıkışma, eşleşme kodu, AES-GCM kayıtları, Anahtar Zinciri) | 4 | mac-host-dev | [T-039] |
| [T-042](tasks/T-042-client-encryption.md) | Tablet — protokol v1 şifreleme (el sıkışma, eşleşme kodu ekranı, AES-GCM kayıtları, Keystore) | 4 | android-client-dev | [T-038] |
| [T-043](tasks/T-043-host-pairing-preapproval.md) | Mac — eşleşme onayı tablet ayrılınca kaybolmasın (ön onay), Parsec'ten onaylanabilsin | 4 | mac-host-dev | [T-041] |
| [T-044](tasks/T-044-client-store-key-on-pairing.md) | Tablet — eşleşme anahtarını PAIRING başında sakla (bağlantı koptuktan sonra onay için) | 4 | android-client-dev | [T-042] |
| [T-045](tasks/T-045-host-fps-experiment-knobs.md) | Mac — 120 fps deneyi için ayar düğmeleri (MATEBRIDGE_FPS, MATEBRIDGE_BITRATE_KBPS) ve kodlama süresi ölçümü | 5 | mac-host-dev | [T-017] |
| [T-046](tasks/T-046-client-request-120hz.md) | Tablet — video yüzeyi için akış fps'inde yenileme iste (setFrameRate) ve gerçek panel hızını ölç | 5 | android-client-dev | [T-045] |
| [T-047](tasks/T-047-host-encoder-throughput.md) | Mac — HEVC kodlayıcı hız ölçümü (2800×1840'ta 120 fps mümkün mü?) ve ayar denemeleri | 5 | mac-host-dev | [T-045] |
| [T-048](tasks/T-048-client-textureview-render.md) | Tablet — TextureView ile gösterim deneyi (Huawei yenileme yöneticisi video yüzeyini 60 Hz'e indiriyor) | 5 | android-client-dev | [T-046] |
| [T-049](tasks/T-049-host-stream-prefs.md) | Mac — STREAM_PREFS: fps (60/120/144) ve küçültülmüş kodlama boyutu (performans modu) | 5 | mac-host-dev | [T-045, T-047] |
| [T-050](tasks/T-050-client-stream-modes.md) | Tablet — görüntü modları (Netlik / Akıcı / Performans / Performans 144): seçim, kalıcılık, STREAM_PREFS | 5 | android-client-dev | [T-046] |
| [T-051](tasks/T-051-refresh-boost-mouse-trackpad.md) | Touchpad/fare ile sürüklerken fps ~68–70, kalemle ~120 — Huawei 120 Hz yükseltmesini fare/touchpad için de sağlamak | 5 | orchestrator | [T-049, T-050] |
| [T-052](tasks/T-052-client-adaptive-pacing.md) | Tablet — uyarlanır kare zamanlaması (en az gecikmeyle takılmasız sunum, 60/120 Hz) | 5 | android-client-dev | [T-050] |
| [T-053](tasks/T-053-host-fast-encoder-60fps.md) | Mac — hızlı kodlayıcı yapılandırması (LLRC'siz, RealTime=false) 60 fps'te de: gecikmeyi düşür | 5 | mac-host-dev | [T-047, T-049] |
| [T-054](tasks/T-054-host-clipboard.md) | Mac — pano paylaşımı (CLIPBOARD, metin) | 5 | mac-host-dev | [T-041] |
| [T-055](tasks/T-055-client-clipboard.md) | Tablet — pano paylaşımı (CLIPBOARD, metin) | 5 | android-client-dev | [T-042] |
| [T-056](tasks/T-056-client-local-pen-overlay.md) | Tablet — yerel kalem göstergesi (imleç noktası + kısa sönümlenen iz) ile algılanan gecikmeyi azalt | 5 | android-client-dev | [T-052] |
| [T-057](tasks/T-057-client-presentation-scheduling.md) | Tablet — sunum zamanlaması düzeltmeleri (yuva başına tek bırakma, son yuvaya gecikme sınırı, faz kalibrasyonu, çözücü doluluğu) | 5 | android-client-dev | [T-052] |
| [T-058](tasks/T-058-host-display-rate-decimation.md) | Mac — DISPLAY_RATE ile kodlamadan önce seyreltme (60/120), yeniden başlatmasız; BoundedFrameQueue kurtarma düzeltmesi | 5 | mac-host-dev | [T-049] |
| [T-059](tasks/T-059-client-display-rate.md) | Tablet — panel hızını host'a bildir (DISPLAY_RATE) | 5 | android-client-dev | [T-057] |
| [T-060](tasks/T-060-client-phase-locked-slots.md) | Tablet — akış hızı panel hızına eşitken faz kilitli yuva ataması (histerezis); seyreltmeyle 33 ms boşlukları gider | 5 | android-client-dev | [T-057, T-059] |
| [T-061](tasks/T-061-client-fixed-lead.md) | Tablet — varsayılan bırakma öncüsü tüm panel hızlarında mutlak 6,0 ms (P − 1 ms ile sınırlı) | 5 | android-client-dev | [T-057, T-060] |
| [T-062](tasks/T-062-idle-freeze.md) | Boşta → hareket geçişinde ve yazarken donma (son kare gönderilmiyor/bırakılmıyor) | 5 | orchestrator | [T-057, T-058, T-060] |
| [T-063](tasks/T-063-clipboard-tablet-to-mac.md) | Pano: tablet → Mac çalışmıyor | 5 | android-client-dev | [T-054, T-055] |
| [T-064](tasks/T-064-pen-overlay-default-off.md) | Yerel kalem izi/noktası varsayılan kapalı | 5 | android-client-dev | [T-056] |
| [T-065](tasks/T-065-client-newest-frame-always-shown.md) | Tablet — en yeni kare her zaman gösterilir (seyrek karelerde faz kilidi kareyi atıyor; yazarken donma) | 5 | android-client-dev | [T-057, T-060, T-061] |
| [T-066](tasks/T-066-host-decimation-hold-last-frame.md) | Mac — seyreltmede ızgaradan erken gelen kare atılmaz, tutulur (son değişiklik her zaman gönderilir) | 5 | mac-host-dev | [T-058] |
| [T-068](tasks/T-068-client-deadline-knob.md) | Tablet — sunum son anı (presentationDeadline) için deney düğmesi ve geç kare kenar payı ölçümü | 5 | android-client-dev | [T-065] |
| [T-069](tasks/T-069-client-pace-trace.md) | Tablet — kare başına sunum izi (pace trace) dosyaya, deney anahtarıyla | 5 | android-client-dev | [T-068] |
| [T-070](tasks/T-070-host-latency-breakdown.md) | Mac — yakalama→gönderim gecikme dökümü (SCK teslim, kodlama, kuyruk, soket yazımı) ve sıçrama kaynağı | 5 | mac-host-dev | [T-066] |
| [T-071](tasks/T-071-client-default-deadline-6ms.md) | Tablet — sunum son anı varsayılanı 6 ms (HarmonyOS'un 13,3 ms değeri yerine) | 5 | android-client-dev | [T-068] |
| [T-072](tasks/T-072-host-latency-metric-and-hold.md) | Mac — gecikme ölçümünün başlangıç noktası (yakalama zamanı) ve 120 fps'te kodlayıcı öncesi bekleme | 5 | mac-host-dev | [T-070] |
| [T-073](tasks/T-073-client-trace-receive-path.md) | Tablet — kare izine alma yolu zamanları (soketten okundu, şifre çözüldü, kuyruğa girdi, çözücüye verildi) | 5 | android-client-dev | [T-069] |
| [T-074](tasks/T-074-client-tcp-quickack.md) | Tablet — USB (adb) tünelinde 40 ms paketlemeyi kır: alma soketinde TCP_QUICKACK | 5 | android-client-dev | [T-073] |
| [T-075](tasks/T-075-host-keyframe-interval.md) | Mac — periyodik anahtar kare aralığı 10 s → isteğe bağlı (uzun güvenlik aralığı) | 5 | mac-host-dev | [T-072] |
| [T-076](tasks/T-076-client-decrypt-speed.md) | Tablet — AES-GCM kayıt şifre çözme hızı (432 KB'de ~11 ms, 3 KB'de ~0,8 ms) | 5 | android-client-dev | [T-073] |
| [T-077](tasks/T-077-client-input-path-latency.md) | Tablet — alımdan çözücüye verme gecikmesi (kuyruk→giriş p50 1,16 / p95 2,7 ms; küçük kayıtta 0,6 ms şifre çözme) | 5 | android-client-dev | [T-076] |
| [T-078](tasks/T-078-client-hiwrite-overlay.md) | Tablet — açılışta ekranın üst ortasında kalem algılanmıyor (Huawei HiWrite katmanı, adres metin kutusu) | 5 | android-client-dev | [] |
| [T-079](tasks/T-079-client-performance-hint.md) | Tablet — PerformanceHintManager deneyi (ağ, çözücü giriş/çıkış iş parçacıkları için kare süresi hedefi) | 5 | android-client-dev | [T-077] |
| [T-080](tasks/T-080-client-constant-playout-pacer.md) | Tablet — sabit oynatma gecikmeli zamanlayıcı (düzensiz içerikte 120 Hz boşluklarını azalt), anahtar arkasında | 5 | android-client-dev | [T-071, T-077] |
| [T-081](tasks/T-081-host-wake-on-display-sleep.md) | Mac — tablet bağlıyken ekran uykusunda görüntü koparsa ekranı uyandır (IOPMAssertionDeclareUserActivity) | 4 | mac-host-dev | [T-040] |
| [T-082](tasks/T-082-h264-vs-hevc-decode.md) | Deney — H.264 ile HEVC karşılaştırması (tablette çözme süresi, kalite, uçtan uca gecikme) | 5 | orchestrator | [T-077] |
| [T-083](tasks/T-083-capture-vsync-phase.md) | Araştırma — Mac yakalama fazını tablet vsync'ine hizalamak (ortalama ~4 ms bekleme kazancı) | 5 | orchestrator | [T-071] |
| [T-084](tasks/T-084-surfacecontrol-presentation.md) | Deney — SurfaceControl/ASurfaceControl ile doğrudan sunum (HarmonyOS'ta compositor gecikmesi) | 5 | orchestrator | [T-071] |
| [T-085](tasks/T-085-bitrate-text-sharpness.md) | Deney — bit hızı/kodlayıcı kalite ayarı ile yazı keskinliği (Akıcı mod) | 5 | orchestrator | [] |
| [T-086](tasks/T-086-host-encoder-quality-knobs.md) | Mac — kodlayıcı deney düğmeleri (H.264, bit hızı, kalite), boşta kalite tazeleme ve keskinlik ölçümü (T-082/T-085) | 5 | mac-host-dev | [T-082, T-085] |
| [T-087](tasks/T-087-host-idle-refresh-real-refine.md) | Mac — boşta tazeleme gerçek hatta kalite artırmıyor (222 baytlık atlama kareleri); düzelt ve ölç | 5 | mac-host-dev | [T-086] |
| [T-088](tasks/T-088-host-wifi-knobs.md) | Mac — Wi-Fi ölçüm altyapısı ve düğmeler (aktarım logu, gönderim kuyruğu ölçümü, Wi-Fi bit hızı, serviceClass) | 5 | mac-host-dev | [T-086] |
| [T-089](tasks/T-089-client-wifi-knobs.md) | Tablet — Wi-Fi ölçüm altyapısı ve düğmeler (RTT istatistiği, aktarım logu, trafik sınıfı, WifiLock düşük gecikme) | 5 | android-client-dev | [T-077] |
| [T-090](tasks/T-090-client-net-bench.md) | Tablet — ham ağ hızı ölçüm kipi (`--es net_bench host:port`), Wi-Fi kapasitesini uygulamadan bağımsız ölçmek için | 5 | android-client-dev | [T-089] |
| [T-091](tasks/T-091-host-video-bsd-socket.md) | Mac — video bağlantısını çekirdek TCP soketine taşı (NWConnection kullanıcı alanı yığını Wi-Fi'de %4 yeniden gönderim) + TCP_NOTSENT_LOWAT | 5 | mac-host-dev | [T-088] |
| [T-092](tasks/T-092-host-video-bsd-default.md) | Mac — video soketi varsayılanı `bsd` (T-091 ölçümü: Wi-Fi 372 → ~40 ms, yeniden gönderim 0) | 5 | mac-host-dev | [T-091] |
