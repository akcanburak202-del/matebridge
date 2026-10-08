# Board

_Otomatik üretildi: `./scripts/board.sh` — elle düzenleme._

## in-progress

| ID | Başlık | Aşama | Sahip | Bağımlılık |
|---|---|---|---|---|
| [T-147](tasks/T-147-recovery-runbook.md) | Write and rehearse the recovery runbook and known-good version pair | 6 | orchestrator | [T-145, T-146] |

## todo

| ID | Başlık | Aşama | Sahip | Bağımlılık |
|---|---|---|---|---|
| [T-157](tasks/T-157-trust-device-acceptance.md) | Run the trust-transition device acceptance (X1) | 6 | orchestrator | [T-150, T-151, T-152, T-153, T-154, T-155, T-156, T-205] |
| [T-164](tasks/T-164-video-fault-churn-device-run.md) | Run decoder fault injection and the surface-churn soak on the tablet | 6 | orchestrator | [T-159, T-161] |
| [T-166](tasks/T-166-parked-display-measurement.md) | Measure parked-display behaviour across sleep, lock and long outages | 6 | user | [T-165, T-147] |
| [T-167](tasks/T-167-host-display-keep-menu.md) | Add a display keep-time preference and "Sanal ekranı şimdi kaldır" to the menu | 6 | mac-host-dev | [T-165, T-166] |
| [T-174](tasks/T-174-optical-latency-baseline.md) | Record the optical input-to-photon baseline (USB/Wi-Fi, 60/120 Hz) | 6 | user | [T-168, T-173] |
| [T-179](tasks/T-179-pen-wifi-rhythm-measurement.md) | Measure Wi-Fi pen arrival rhythm after T-111 across 3 topologies | 6 | orchestrator | [T-171, T-127] |
| [T-180](tasks/T-180-pen-keyboard-validation-matrix.md) | Run the pen and keyboard device validation matrix | 6 | orchestrator | [] |
| [T-192](tasks/T-192-host-settings-reset.md) | Add "Ayarları sıfırla" to the menu (approvals kept) | 6 | mac-host-dev | [T-167, T-189] |
| [T-193](tasks/T-193-readme-plan-refresh.md) | Rewrite the README to the current state; refresh PLAN status; record the version pair | 6 | orchestrator | [T-145, T-146, T-147] |
| [T-194](tasks/T-194-soak-8h-week.md) | Run the 8 h soak, then one week of real use, with resource trends | 6 | user | [T-173, T-157, T-164, T-167, T-193] |
| [T-197](tasks/T-197-client-ctl-lowat-knob.md) | Experiment knob: TCP_NOTSENT_LOWAT on the client control socket | 6 | android-client-dev | [T-127, T-171] |
| [T-198](tasks/T-198-host-pen-playout-experiment.md) | Experimental bounded pen playout on Wi-Fi (knob, default off) | 6 | mac-host-dev | [T-179, T-171] |
| [T-199](tasks/T-199-host-stale-input-policy.md) | Apply the stale-input policy on the host | 6 | mac-host-dev | [T-171, T-175] |
| [T-200](tasks/T-200-host-display-keep-on-failure.md) | Keep a healthy display when capture or the encoder fails | 6 | mac-host-dev | [T-165, T-166] |
| [T-202](tasks/T-202-host-crash-restart-agent.md) | Relaunch the host after a crash (LaunchAgent with KeepAlive) | 6 | mac-host-dev | [T-147, T-148] |
| [T-307](tasks/T-307-str8-invalid-utf8.md) | Protokol — str8 içinde geçersiz UTF-8 iki tarafta da protokol hatası (E9); fixture invalid_str8_utf8 | 7 | orchestrator | [] |
| [T-308](tasks/T-308-audio-sleep-gate-generation.md) | Host — ses uyku kapısı; kuyrukta bekleyen eski uyanma, yeni bir uykunun kapısını temizlemesin (uyku kuşağı) | 7 | mac-host-dev | [T-299] |
| [T-310](tasks/T-310-decode-clock-60fps.md) | Ölçüm — 2800×1840@60'ta çözme süresi kare süresini aşıyor (Günlük'te karelerin %31'i > 16,7 ms); saat, DVFS ve girdi yükseltmesi | 7 | orchestrator | [T-306] |
| [T-312](tasks/T-312-client-decoder-output-park.md) | Tablet — codec boşken çözücü çıkış iş parçacığı park eder (CB2, A/B anahtarı); Tam renk aux çözücü ve GL beklemesi olay tabanlı (C10/CB9) | 7 | android-client-dev | [T-303] |

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
| [T-019](tasks/T-019-gl-jitter-wifilock.md) | Akıcılık — GL yolunda titreşim tamponu ve Wi-Fi düşük gecikme kilidi | 1 | android-client-dev | [T-018] |
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
| [T-067](tasks/T-067-client-lock-recenter.md) | Tablet — faz kilidi geç kare oranına göre yeniden ortalanır; boşta kalınca jitter geçmişi silinmez | 5 | android-client-dev | [T-065] |
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
| [T-093](tasks/T-093-audio-protocol-codecs.md) | Ses protokolü kod çözücüleri (Swift + Kotlin): AUDIO_PREFS / AUDIO_CONFIG / AUDIO_FRAME, HELLO bit8 AUDIO_PCM | 5 | mac-host-dev | [] |
| [T-094](tasks/T-094-host-audio-capture.md) | Mac — sistem sesi yakalama (Core Audio process tap, mutedWhenTapped) ve kontrol bağlantısından AUDIO_FRAME gönderimi | 5 | mac-host-dev | [T-093] |
| [T-095](tasks/T-095-client-audio-playout.md) | Tablet — ses çalma (AudioTrack düşük gecikme, titreşim tamponu, saat kayması yeniden örnekleme, A/V hizalama) | 5 | android-client-dev | [T-093] |
| [T-096](tasks/T-096-client-auto-transport.md) | Tablet — "Otomatik" bağlantı modu (USB varsa USB, yoksa Wi-Fi; akış sırasında kablo takılınca/çekilince geçiş) | 4 | android-client-dev | [T-089] |
| [T-097](tasks/T-097-audio-latency.md) | Ses gecikmesi — sessizlik aralarını alt taşma saymamak, tablet tampon boyu, AAudio MMAP denemesi (karar gerekir) | 5 | orchestrator | [T-095] |
| [T-098](tasks/T-098-client-audio-silence-buffer.md) | Tablet — ses: sessizlik aralarını alt taşma saymamak, ses başlangıcında hızlı çalma, AudioTrack tamponu 1920 → 960 | 5 | android-client-dev | [T-095] |
| [T-099](tasks/T-099-aaudio-mmap-probe.md) | Sonda — AAudio MMAP tablette var mı, çıkış gecikmesi AudioTrack'e göre ne kadar düşük (NDK kurulumu dahil) | 5 | android-client-dev | [T-095] |
| [T-100](tasks/T-100-client-aaudio-output.md) | Tablet — ses çıkışı AAudio MMAP (NDK/C++), AudioTrack'e otomatik geri dönüş | 5 | android-client-dev | [T-098, T-099] |
| [T-101](tasks/T-101-client-audio-output-setting.md) | Tablet — panelde "Ses çıkışı" seçeneği (Düşük gecikme / Uyumlu) ve AAudio gecikme ölçümü düzeltmesi | 5 | android-client-dev | [T-100, T-096] |
| [T-102](tasks/T-102-settings-while-streaming.md) | Taslak — bağlıyken açılabilen ayarlar paneli (akış sürerken, bağlantı paneline dönmeden) | 4 | orchestrator | [T-096, T-101] |
| [T-103](tasks/T-103-host-relative-pointer-games.md) | Mac — göreli fare (touchpad/fare) oyunlarda görünmez duvara takılıyor; gerçek imleç konumundan başla, ham delta gönder | 5 | mac-host-dev | [T-034] |
| [T-104](tasks/T-104-settings-protocol-codecs.md) | Ayarlar paneli protokolü kod çözücüleri (Swift + Kotlin) — STREAM_PREFS.bitrate_kbps, SETTINGS_OPEN (0x08), HELLO bit9 | 4 | mac-host-dev | [] |
| [T-105](tasks/T-105-client-settings-side-panel.md) | Tablet — akış sırasında sağ yan ayarlar paneli (Ctrl+Shift+6, SETTINGS_OPEN), bit hızı seçimi | 4 | android-client-dev | [T-104] |
| [T-106](tasks/T-106-host-bitrate-pref-settings-menu.md) | Mac — STREAM_PREFS.bitrate_kbps uygulaması ve menüde "Tablette ayarları aç" (SETTINGS_OPEN) | 4 | mac-host-dev | [T-104] |
| [T-107](tasks/T-107-client-settings-button-colors.md) | Tablet — ayar panelinde seçili olmayan seçenekler beyaz kutu, yazı görünmüyor | 4 | android-client-dev | [T-105] |
| [T-108](tasks/T-108-client-aaudio-underrun-crackle.md) | Tablet — Düşük gecikme (AAudio) seste oyun sırasında cızırtı; güvenli başlangıç tamponu, öğrenilen değeri hatırlama, boşalmada yumuşak geçiş | 5 | android-client-dev | [T-101] |
| [T-109](tasks/T-109-client-game-mode.md) | Tablet — "Oyun" görüntü modu (120 fps, %66, jitter 0) ve geçici oyun varsayılanları | 5 | android-client-dev | [T-105, T-107] |
| [T-110](tasks/T-110-client-aaudio-mmap-headroom.md) | Tablet — Düşük gecikme (AAudio MMAP) seste oyun modunda sürekli cızırtı; çıkış payı ölçümü ve uyarlamalı çıkış arabelleği | 5 | android-client-dev | [T-108] |
| [T-111](tasks/T-111-host-control-bsd-socket.md) | Mac — kontrol bağlantısını (girdi, ses, kontrol mesajları) çekirdek TCP soketine taşı (T-091'in kontrol karşılığı) | 5 | mac-host-dev | [T-091, T-092] |
| [T-112](tasks/T-112-client-flaky-frame-queue-test.md) | Tablet testi — InputHandoffTest zaman aşımı testi yük altında ara sıra kırılıyor | 5 | android-client-dev | [] |
| [T-113](tasks/T-113-host-encode-time-gap.md) | Mac — uygulamadaki kodlama süresi (enc_ms ~9,5 ms) yalıtılmış bench'ten (~6,4 ms) neden uzun? Ölç, nedeni bul | 5 | mac-host-dev | [] |
| [T-114](tasks/T-114-client-aaudio-default-4-bursts.md) | Tablet — AAudio çıkış arabelleği varsayılanı 4 burst (20 ms); cızırtı deneyle doğrulandı. Çıkış payı ölçümü bu cihazda hep dolu görünüyor | 5 | android-client-dev | [T-110] |
| [T-115](tasks/T-115-client-sparse-frame-no-hold.md) | Tablet — seyrek karelerde (boşluktan sonraki ilk kare) kilit tutmasını kaldır; boşta görüntü gecikmesi bir vsync azalsın | 5 | android-client-dev | [] |
| [T-116](tasks/T-116-host-audio-send-timing.md) | Host — ses gönderim zamanlaması ölçümü (oturum kuyruğu bekleme, yakalama→yazım, yazımlar arası en büyük aralık) | 5 | mac-host-dev | [] |
| [T-117](tasks/T-117-client-audio-arrival-timing.md) | Tablet — ses paketi varış ölçümü (varış aralığı, tek yön gecikme, okuma başına paket) ve boşlukta video okuyucuyla karşılaştırma | 5 | android-client-dev | [] |
| [T-118](tasks/T-118-client-audio-safety-balanced.md) | Tablet — ses güvenlik payı "dengeli" politika (hızlı küçülme, hatırlanan değer en çok 30 ms, alt taşma sonrası aşırı dolumu kısalt) | 5 | android-client-dev | [T-117] |
| [T-119](tasks/T-119-host-audio-tap-create-retry.md) | Host — ses tap'i oluşturulamazsa (oturum devri yarışı) kalıcı vazgeçme; kısa gecikmeyle yeniden dene | 5 | mac-host-dev | [] |
| [T-120](tasks/T-120-client-stall-detector.md) | Tablet — süreç donma dedektörü (yüksek öncelikli tik iş parçacığı); ses/görüntü varış boşluklarının tabletten mi geldiğini ayır | 5 | android-client-dev | [T-117] |
| [T-121](tasks/T-121-client-keyframe-storm.md) | Tablet — kısa kare yığılmasında keyframe fırtınası (MAX_PENDING=2 → bırak-hepsini + KEYFRAME_REQUEST); yığılmayı yut, istekleri sınırla | 5 | android-client-dev | [T-120] |
| [T-122](tasks/T-122-host-keyframe-request-coalesce.md) | Host — art arda gelen KEYFRAME_REQUEST'leri birleştir (bir IDR yoldayken yenisini zorlama); IDR boyutunu logla | 5 | mac-host-dev | [] |
| [T-123](tasks/T-123-client-audio-safety-per-transport.md) | Tablet — ses güvenlik payı bağlantı türüne göre (USB / Wi-Fi ayrı hatırlansın, Wi-Fi tabanı yüksek); geçişte pay hemen uyarlansın | 5 | android-client-dev | [T-118] |
| [T-124](tasks/T-124-host-wifi-service-class-default.md) | Host — Wi-Fi'de varsayılan servis sınıfı `signaling` (kontrol/ses AC_VO, video AC_VI) | 5 | mac-host-dev | [] |
| [T-125](tasks/T-125-client-audio-late-bunch-skip.md) | Tablet — alt taşmadan sonra geç gelen toplu ses paketleri seviyeyi şişirmesin (çalarken ileri atla, yumuşak geçişle) | 5 | android-client-dev | [T-118, T-123] |
| [T-126](tasks/T-126-host-tcp-info-control-video.md) | Host — kontrol (ses) ve video soketlerinin TCP durumunu saniyelik logla (yeniden gönderim, RTO, srtt, gönderilmemiş/onaylanmamış bayt) | 5 | mac-host-dev | [T-124] |
| [T-127](tasks/T-127-wifi-video-burst-pacing.md) | Measure the Wi-Fi baseline across three topologies before any congestion code | 6 | orchestrator | [T-126, T-168, T-170, T-173] |
| [T-128](tasks/T-128-host-sleep-policy-wol-txt.md) | Mac — kasıtlı uykuya saygı, oturumda ekran uykusunu önle, Bonjour TXT `wol` (Wake-on-LAN adresleri) | 4 | mac-host-dev | [T-081] |
| [T-129](tasks/T-129-client-wake-on-lan.md) | Tablet — Mac bulunamayınca Wake-on-LAN magic packet ile uyandır (TXT `wol`) | 4 | android-client-dev | [] |
| [T-130](tasks/T-130-host-app-icon.md) | Mac — uygulama ikonu ve menü çubuğu simgesi (öneri C "M çizgisi") | 5 | mac-host-dev | [] |
| [T-131](tasks/T-131-client-app-icon.md) | Tablet — uygulama ikonu (öneri C "M çizgisi", adaptive icon) | 5 | android-client-dev | [] |
| [T-132](tasks/T-132-host-bye-host-sleep.md) | Mac — uykuya girerken oturumu BYE(HOST_SLEEP) ile kapat | 4 | mac-host-dev | [T-128] |
| [T-133](tasks/T-133-client-host-sleep-and-usb-wol.md) | Tablet — BYE(HOST_SLEEP) sonrası "Mac uyku modunda" (otomatik yeniden bağlanma yok); USB'de de `wol` öğren | 4 | android-client-dev | [T-129] |
| [T-134](tasks/T-134-client-wake-by-direct-connect.md) | Tablet — Mac'i saklanan IP'ye doğrudan TCP bağlanarak uyandır (magic packet işe yaramıyor) | 4 | android-client-dev | [T-133] |
| [T-135](tasks/T-135-client-files-webdav.md) | Tablet — dosyalar için WebDAV sunucusu (yalnız localhost, jetonlu, hız tavanlı) + FILES_INFO | 5 | android-client-dev | [] |
| [T-136](tasks/T-136-host-files-mount.md) | Mac — FILES_INFO ile adb forward, WebDAV birimini bağla, menü "Tablet dosyalarını aç" | 5 | mac-host-dev | [] |
| [T-137](tasks/T-137-files-mount-90s-delay.md) | Dosyalar — Finder'da bağlama her seferinde tam 90 s sürüyor (kök neden + düzeltme) | 5 | android-client-dev | [T-135, T-136] |
| [T-138](tasks/T-138-files-bulk-blocks-small.md) | Dosyalar — Finder'ın video önizlemeleri tüm dosyayı indiriyor, küçük kopyalar "hazırlanıyor"da takılıyor | 5 | android-client-dev | [T-137] |
| [T-139](tasks/T-139-files-connection-limit-fix.md) | Dosyalar — bağlantı sınırı 8, yalnız gerçekten boştaki bağlantıyı düşür, ilerlemeyen yazımı kapat | 5 | android-client-dev | [T-138] |
| [T-140](tasks/T-140-refresh-vote-experiment.md) | Deney — dokunmadan 120 Hz için "animasyon oyu" (açılış parametresiyle, varsayılan kapalı) | 5 | android-client-dev | [] |
| [T-141](tasks/T-141-idle-power.md) | Durgun ekranda istemciyi uyutmak (vsync döngüleri, boş iş) ve normal kullanımda log azaltmak | 5 | android-client-dev | [T-140] |
| [T-142](tasks/T-142-stall-detector-opt-in.md) | Ses takılma dedektörünü (mb-stall) açılış parametresine bağla, varsayılan kapalı | 5 | android-client-dev | [T-120, T-141] |
| [T-143](tasks/T-143-game60-mode.md) | "Oyun 60" modunu ekle, mevcut Oyun modunu "Oyun 120" olarak adlandır | 5 | android-client-dev | [T-109] |
| [T-144](tasks/T-144-drawing-mode.md) | "Çizim" modunu ekle (120 fps, %90) ve ölçek deneme parametresi | 5 | android-client-dev | [T-143] |
| [T-145](tasks/T-145-host-build-identity.md) | Log and show the host build commit | 6 | mac-host-dev | [] |
| [T-146](tasks/T-146-client-build-identity.md) | Log and show the client build commit | 6 | android-client-dev | [] |
| [T-148](tasks/T-148-host-login-item-retry.md) | Retry login-item registration after a failure | 6 | mac-host-dev | [] |
| [T-149](tasks/T-149-ci-merge-gate.md) | Add a component-split CI merge gate and a safe fixture CLI | 6 | orchestrator | [] |
| [T-150](tasks/T-150-client-pending-pair-trust.md) | Keep new pair keys pending until local confirmation and pair only on user action | 6 | android-client-dev | [T-042, T-044] |
| [T-151](tasks/T-151-client-trust-ui.md) | Add pairing confirm/cancel, the new-host pick prompt and "Bu Mac'i unut" | 6 | android-client-dev | [T-150] |
| [T-152](tasks/T-152-host-paired-proof-first.md) | Activate PAIRED sessions only after the first authenticated record | 6 | mac-host-dev | [T-041] |
| [T-153](tasks/T-153-client-files-session-lifetime.md) | Run the WebDAV server only during an accepted, trusted USB session | 6 | android-client-dev | [T-151] |
| [T-154](tasks/T-154-client-data-extraction-rules.md) | Exclude app data from device-to-device and cloud transfer | 6 | android-client-dev | [] |
| [T-155](tasks/T-155-host-orphan-approval-guard.md) | Flag a replaced orphan approval request on the Mac | 6 | mac-host-dev | [T-152] |
| [T-156](tasks/T-156-client-key-mismatch-state.md) | Show "anahtar uyuşmuyor" after repeated PAIRED auth failures | 6 | android-client-dev | [T-151] |
| [T-158](tasks/T-158-client-decoder-backend-seam.md) | Put MediaCodec behind a DecoderCodec interface (no behaviour change) | 6 | android-client-dev | [] |
| [T-159](tasks/T-159-client-video-health-gate.md) | Gate input on decoder health and show a video-fault overlay | 6 | android-client-dev | [T-158] |
| [T-160](tasks/T-160-client-video-delivery-gate.md) | Drop video frames from stale connections and uninstalled configs | 6 | android-client-dev | [T-159, T-150] |
| [T-161](tasks/T-161-client-decoder-teardown-bounds.md) | Bound the decoder hand-off, join the output thread, keep per-generation state | 6 | android-client-dev | [T-159, T-160] |
| [T-162](tasks/T-162-host-encoder-submit-owner.md) | Serialise HEVCEncoder submits, QP updates and teardown on one owner queue | 6 | mac-host-dev | [] |
| [T-163](tasks/T-163-host-key-repeat-stall-pause.md) | Pause host key auto-repeat while the control connection is silent | 6 | mac-host-dev | [] |
| [T-165](tasks/T-165-host-park-virtual-display.md) | Park the virtual display after a session ends (no capture or encode while parked) | 6 | mac-host-dev | [] |
| [T-168](tasks/T-168-client-latency-stage-stats.md) | Break client latency into stages with percentiles; stop clamping; fix stats maps; log decoder hardware | 6 | android-client-dev | [T-161] |
| [T-169](tasks/T-169-client-refresh-target-log.md) | Log target and real refresh separately; warn on a mismatch | 6 | android-client-dev | [T-168] |
| [T-170](tasks/T-170-host-latency-trace-join.md) | Make the host latency CSV joinable with the tablet trace; fix labels | 6 | mac-host-dev | [T-162] |
| [T-171](tasks/T-171-host-input-age-ping.md) | Measure input age at injection through host PING (diagnostics only) | 6 | mac-host-dev | [T-152, T-163] |
| [T-172](tasks/T-172-latency-semantics-docs.md) | Record decision 0021 and correct the latency and late-input prose | 6 | orchestrator | [T-170] |
| [T-173](tasks/T-173-measurement-kit-smoke.md) | Version the measurement and soak scripts and add device-smoke.sh | 6 | orchestrator | [T-145, T-146] |
| [T-175](tasks/T-175-host-input-delivery-timing.md) | Time host input delivery, environment lookups and CGEventPost per message | 6 | mac-host-dev | [T-171] |
| [T-176](tasks/T-176-host-drop-idr-feedback.md) | Stop forced-IDR feedback on host-side queue drops | 6 | mac-host-dev | [T-162] |
| [T-177](tasks/T-177-host-live-bitrate-setter.md) | Add a live encoder bitrate setter (no restart) and verify VT honours it | 6 | mac-host-dev | [T-162, T-176] |
| [T-178](tasks/T-178-host-wifi-default-bitrate.md) | Use a conservative default bitrate on Wi-Fi (host only) | 6 | mac-host-dev | [T-127] |
| [T-181](tasks/T-181-palm-before-pen-measurement.md) | Measure palm-before-pen clicks and the touchMajor distribution | 6 | orchestrator | [] |
| [T-182](tasks/T-182-experiment-knob-inventory.md) | Record decision 0026 and the knob inventory; close T-019 and T-067 | 6 | orchestrator | [] |
| [T-183](tasks/T-183-client-retire-experiments.md) | Retire concluded client experiments (perf hint, rvote, cpd, …; Wi-Fi knobs kept) | 6 | android-client-dev | [T-182, T-168] |
| [T-184](tasks/T-184-client-retire-gl-path.md) | Retire the GL presentation path | 6 | android-client-dev | [T-183] |
| [T-185](tasks/T-185-client-dev-knob-gate.md) | Gate debug extras behind `dev`; add `ev=profile`; move NetBench to debug | 6 | android-client-dev | [T-184, T-146] |
| [T-186](tasks/T-186-host-retire-experiments.md) | Retire the host Network.framework (`nw`) socket stack | 6 | mac-host-dev | [T-182, T-171] |
| [T-187](tasks/T-187-host-encoder-hw-warning.md) | Warn when VideoToolbox did not select the hardware encoder | 6 | mac-host-dev | [T-204] |
| [T-188](tasks/T-188-colour-range-check.md) | Check stream colour, range and chroma fidelity with test patterns | 6 | user | [] |
| [T-189](tasks/T-189-host-usb-only-profile.md) | Add a "Yalnız USB" network profile | 6 | mac-host-dev | [] |
| [T-190](tasks/T-190-client-share-folder-scope.md) | Share a chosen folder (optional read-only) instead of all storage | 6 | android-client-dev | [T-153] |
| [T-191](tasks/T-191-client-settings-reset.md) | Add "Varsayılanlara dön" (settings + learned audio state; pairing kept) | 6 | android-client-dev | [T-185] |
| [T-195](tasks/T-195-core-congestion-controller.md) | Write a pure Wi-Fi congestion controller (in-flight budget, fast-down/slow-up) | 6 | mac-host-dev | [T-127] |
| [T-196](tasks/T-196-host-wifi-adaptive-send.md) | Wire the congestion controller into the video gate and the encoder (Wi-Fi, knob) | 6 | mac-host-dev | [T-177, T-195] |
| [T-201](tasks/T-201-host-chroma-bench.md) | Add an RGB-referenced chroma metric and test patterns to SharpnessBench | 6 | mac-host-dev | [T-188, T-204] |
| [T-203](tasks/T-203-client-palm-size-filter.md) | Contact-size palm filter | 6 | android-client-dev | [T-181] |
| [T-204](tasks/T-204-host-retire-encoder-knobs.md) | Retire concluded host encoder experiments (idle refresh, …); add host `ev=profile` | 6 | mac-host-dev | [T-182, T-177, T-145] |
| [T-205](tasks/T-205-client-migration-auth-gate.md) | Promote an AUTO USB migration candidate only after its first authenticated host record | 6 | android-client-dev | [T-150] |
| [T-206](tasks/T-206-host-files-auto-remount.md) | Remount the tablet files volume after a server restart if it was mounted | 6 | mac-host-dev | [T-190] |
| [T-207](tasks/T-207-client-clear-usb-asked-after-trust.md) | Clear the "asked to pair" mark on a Mac's endpoints once that Mac is trusted, so AUTO returns to USB | 6 | android-client-dev | [T-151] |
| [T-208](tasks/T-208-client-integer-cadence-lock.md) | Phase-lock 60 fps content on a 120 Hz panel (integer cadence lock) | 6 | android-client-dev | [T-168, T-183] |
| [T-209](tasks/T-209-host-force-unmount-stale-volume.md) | Force-unmount a stale tablet files volume when its token is dead, then remount | 6 | mac-host-dev | [T-206] |
| [T-210](tasks/T-210-client-game-mode-adaptive-pacer-ab.md) | Let the dev jitter knob select the adaptive pacer in game modes (A/B for T-208) | 6 | android-client-dev | [T-208, T-185] |
| [T-211](tasks/T-211-client-game-mode-adaptive-default.md) | Game modes use the adaptive pacer by default (decision 0014 §2 amended) | 6 | android-client-dev | [T-208, T-210] |
| [T-213](tasks/T-213-game-display-protocol.md) | STREAM_PREFS optional game display group: codecs and fixture tests (Swift + Kotlin) | 6 | orchestrator | [] |
| [T-214](tasks/T-214-host-game-display.md) | Host: 1x game display at the requested pixel size (decision 0029) | 6 | mac-host-dev | [T-213] |
| [T-215](tasks/T-215-client-game-resolution.md) | Client: "Oyun çözünürlüğü" setting and game display prefs (decision 0029) | 6 | android-client-dev | [T-213] |
| [T-216](tasks/T-216-game-display-measurement.md) | Device measurement: game display sizes vs native (decision 0029) | 6 | orchestrator | [T-214, T-215] |
| [T-217](tasks/T-217-client-decoder-latency-knobs-ab.md) | A/B HiSilicon decoder low-latency keys and operating rate (dev knob) | 6 | android-client-dev | [T-185, T-219] |
| [T-218](tasks/T-218-client-video-loss-input-gate.md) | Gate input on video-only loss (stale picture must not keep input live) | 6 | android-client-dev | [T-159, T-160] |
| [T-219](tasks/T-219-client-decoder-queue-generation-ownership.md) | Decoder input queue: a retired generation must not consume the next generation's frames | 6 | android-client-dev | [T-161] |
| [T-220](tasks/T-220-client-presentation-metric-and-game120-cadence.md) | One presentation metric across pacers; infer 60 fps cadence in Oyun 120 | 6 | android-client-dev | [T-208, T-211] |
| [T-221](tasks/T-221-hotfix-input-viewport.md) | Hotfix — input viewport stays empty after T-215's MATCH_PARENT layout | 6 | orchestrator | [T-215] |
| [T-222](tasks/T-222-client-operating-rate-max-default.md) | Decoder operating rate "max" by default (device A/B result of T-217) | 6 | android-client-dev | [T-217] |
| [T-223](tasks/T-223-client-modes-daily-drawing-game.md) | Client — three modes (Günlük / Çizim / Oyun), per-mode frame rate setting, 2240×1472 game resolution | 6 | android-client-dev | [T-215, T-222] |
| [T-224](tasks/T-224-host-single-instance.md) | Host — only one MateBridge instance may run (second instance exits) | 6 | mac-host-dev | [T-148] |
| [T-225](tasks/T-225-client-callback-presentation-metric.md) | Client — base the presentation metric (skip_pct) on frame-rendered callbacks; the latch model miscounts ~20% of game frames and pins the pacer at its cap | 6 | android-client-dev | [T-220, T-222] |
| [T-226](tasks/T-226-hdr-feasibility-research.md) | Research — can MateBridge stream HDR (HDR virtual display → 10-bit HEVC → HDR10/HLG on the tablet)? Feasibility and cost, no product code | 6 | orchestrator | [T-188] |
| [T-227](tasks/T-227-client-endpoint-rediscovery.md) | Client — when the stored Mac address stops answering, rediscover the host via Bonjour (Mac moved from Wi-Fi to Ethernet) | 6 | android-client-dev | [] |
| [T-228](tasks/T-228-host-usb-watcher-skip-network-adb.md) | Host — the USB tunnel watcher must ignore network adb devices (adb over Wi-Fi is not USB) | 6 | mac-host-dev | [] |
| [T-229](tasks/T-229-client-rediscovery-multi-mac.md) | Client — T-227 rediscovery edge cases with more than one paired Mac (candidate starvation, user pick inherits identity gate) | 6 | android-client-dev | [T-227] |
| [T-230](tasks/T-230-black-level-bitstream-probe.md) | Black level lifted on the tablet (Mac 0 → tablet 16) — Mac-side bitstream probe (what Y values and VUI the encoder really emits) | 6 | mac-host-dev | [] |
| [T-231](tasks/T-231-client-color-override-knobs.md) | Black level lifted on the tablet — client dev knobs to override colour range/standard/transfer and a logged output-format report (A/B on device) | 6 | android-client-dev | [] |
| [T-232](tasks/T-232-host-hdr-display-knob.md) | Host dev knob — create the MateBridge virtual display with an HDR transfer function (tf=1) so games can be checked for an HDR toggle; stream stays SDR | 6 | mac-host-dev | [T-226] |
| [T-233](tasks/T-233-yuv444-research.md) | Research — 4:4:4 chroma (HEVC RExt or alternatives) for sharp coloured edges: Mac encoder support, tablet decoder support, cost | 6 | orchestrator | [] |
| [T-234](tasks/T-234-client-idle-dim-off.md) | Client — idle dim then screen-off per decision 0031 (panel setting 2/5/10/15/off, first input only wakes, paused in game mode) | 6 | android-client-dev | [] |
| [T-235](tasks/T-235-host-chroma-knob.md) | Host dev knob MATEBRIDGE_CHROMA=420|sharp_bilinear|sharp_nearest|444 — sharp-YUV (luma adjustment) 4:2:0 via a Metal pass, plus a native 4:4:4 probe value; colour test page | 6 | mac-host-dev | [T-233] |
| [T-237](tasks/T-237-host-hdr10-pipeline.md) | Host — HDR10 per decision 0032 (STREAM_PREFS dynamic_range codec + HDR display, SCK HDR capture, VT Main10 PQ, SDR fallback) | 6 | mac-host-dev | [T-232] |
| [T-238](tasks/T-238-client-hdr10.md) | Client — HDR10 per decision 0032 (STREAM_PREFS dynamic_range codec, capability check, Oyun-mode panel toggle, decoder setup, logs) | 6 | android-client-dev | [T-231] |
| [T-240](tasks/T-240-host-chroma-pref.md) | Host — apply STREAM_PREFS.chroma (decision 0033) via the T-235 sharp_nearest path; codec field rename | 6 | mac-host-dev | [T-235, T-237] |
| [T-241](tasks/T-241-client-chroma-pref.md) | Client — "Keskin renk kenarları" panel toggle and STREAM_PREFS.chroma (decision 0033) | 6 | android-client-dev | [T-238] |
| [T-242](tasks/T-242-client-auto-bitrate-in-mode-layer.md) | Client — "Otomatik" bit rate picked inside Oyun/Çizim must mean the layer default (60 Mbps), not the host formula | 6 | android-client-dev | [] |
| [T-243](tasks/T-243-client-pin-60hz-experiment.md) | Client experiment — keep the panel at 60 Hz in Oyun 60 despite touch (preferredRefreshRate and other platform hints), knob first | 6 | android-client-dev | [] |
| [T-244](tasks/T-244-host-limited-range-knob.md) | Host experiment — encode limited (video) range (SCK 420v, VUI full=0, STREAM_CONFIG full_range=0) to fix the black lift when the tablet scales the picture | 6 | mac-host-dev | [T-230] |
| [T-245](tasks/T-245-client-game-native-2800-option.md) | Client — experimental "2800×1840 (deneysel)" game resolution, offered only in Oyun 60 | 6 | android-client-dev | [] |
| [T-246](tasks/T-246-client-no-focus-highlight.md) | Client — disable Android's default focus highlight on the video SurfaceView (the intermittent "grey" black lift) | 6 | android-client-dev | [] |
| [T-247](tasks/T-247-client-first-nav-key-after-touch.md) | Client — verify (and fix) that the first navigation key after a touch is not swallowed by ViewRootImpl leaving touch mode | 6 | android-client-dev | [] |
| [T-248](tasks/T-248-decoder-concurrency-probe.md) | Probe — does the tablet's HEVC decoder scale with concurrent sessions? (1 vs 2 vs 3 decoders, full vs half frames) | 6 | android-client-dev | [] |
| [T-249](tasks/T-249-decoder-probe-10bit-bitrate.md) | Probe — decoder headroom for 10-bit (SDR + HDR PQ) and high bitrates (60–150 Mbps) at 2800×1840 | 6 | android-client-dev | [T-248] |
| [T-250](tasks/T-250-client-2800-at-oyun-120.md) | Client — allow 2800×1840 game resolution in Oyun 120 too (drop the 60-only rule) | 6 | android-client-dev | [T-245, T-249] |
| [T-251](tasks/T-251-client-pacer-120-diagnostics.md) | Client — 120 Hz pacer diagnostics: log feedback level, dev knobs for D cap and feedback | 6 | android-client-dev | [] |
| [T-252](tasks/T-252-client-catch-up-instead-of-flush.md) | Client — on queue overflow, decode the backlog fast and show only the newest frame instead of flushing + keyframe request | 6 | android-client-dev | [T-251] |
| [T-253](tasks/T-253-host-static-refinement-frame.md) | Host — "refine when still": after motion stops, send one high-quality frame of the unchanged screen | 6 | mac-host-dev | [] |
| [T-254](tasks/T-254-probe-yuv444-tablet.md) | Probe (tablet) — 4:4:4 packing gates: raw YUV sampling on the GPU, ImageReader→GL→SurfaceView presentation, dual decode at 60 fps | 6 | android-client-dev | [] |
| [T-255](tasks/T-255-probe-yuv444-mac.md) | Probe (Mac) — 4:4:4 packing costs: Metal packer time, two VT sessions at 60 fps, auxiliary bitrate, reconstruction quality; v2 test clips | 6 | mac-host-dev | [] |
| [T-256](tasks/T-256-probe-yuv444-gl-latency.md) | Probe (tablet) — 4:4:4 GL merge path latency with depth-1 presentation vs today's direct path | 6 | android-client-dev | [T-254] |
| [T-257](tasks/T-257-full-chroma-protocol.md) | Protocol — packed full chroma (decision 0034): STREAM_PREFS.chroma=2, STREAM_CONFIG.chroma_layout, VIDEO_FRAME.view, KEYFRAME_REQUEST.view | 6 | orchestrator | [T-254, T-255, T-256] |
| [T-258](tasks/T-258-host-full-chroma.md) | Host — packed full chroma (decision 0034): codecs, Metal AVC444v2 packer, second VT session, pairing, fallback | 6 | mac-host-dev | [T-257, T-253] |
| [T-259](tasks/T-259-client-full-chroma.md) | Client — packed full chroma (decision 0034): codecs, capability test, second decoder, ImageReader + GL merge path, pairing, prefs | 6 | android-client-dev | [T-257, T-252] |
| [T-260](tasks/T-260-client-colour-panel.md) | Client panel — "Renk: Normal / Keskin kenarlar / Tam renk" (decision 0034), migrate the 0033 setting | 6 | android-client-dev | [T-259] |
| [T-261](tasks/T-261-client-full-chroma-temporal-reuse.md) | Client — full chroma without flicker: keep the last full colour in unchanged blocks when the aux frame is late, upgrade late pairs | 6 | android-client-dev | [T-259] |
| [T-262](tasks/T-262-host-aux-size.md) | Host — shrink the full-chroma auxiliary stream (aux bytes are 1.25–1.5× main instead of ~0.4×) | 6 | mac-host-dev | [T-258] |
| [T-263](tasks/T-263-full-chroma-hotfix.md) | Client — Tam renk acil düzeltme: ana ImageReader 6 imaj, ana dekoder çökünce negotiated geri dönüş, "Görüntü durdu" düğmesi okunur | 6 | android-client-dev | [T-261] |
| [T-264](tasks/T-264-default-sharp-colour.md) | Client — "Renk" varsayılanı Keskin kenarlar (0034 eki) | 6 | android-client-dev | [T-260] |
| [T-265](tasks/T-265-files-net-protocol.md) | Protocol — Wi-Fi tablet files (decision 0035): HELLO bit12, FILES_INFO STANDBY, FILES_NET, file connection 0x50–0x52, §9 file keys | 6 | orchestrator | [] |
| [T-266](tasks/T-266-client-files-wifi-profile.md) | Client files/ — Wi-Fi profili: değişebilir hız tavanı + küçük istek şeridi, Wi-Fi kökü MateBridge/Wi-Fi, hızlı 404 | 6 | android-client-dev | [] |
| [T-267](tasks/T-267-host-core-files-net.md) | Host Core — Wi-Fi dosyaları (0035): kodekler, dosya anahtarları, planner ağ dalı, FilesRateCap | 6 | mac-host-dev | [T-265] |
| [T-268](tasks/T-268-host-app-files-proxy.md) | Host App — Wi-Fi dosyaları (0035): dosya dinleyicisi + kanıt, FilesNetProxy (127.0.0.1:47012), menü | 6 | mac-host-dev | [T-267] |
| [T-269](tasks/T-269-client-files-tunnel.md) | Client — Wi-Fi dosyaları (0035): kodekler, dosya anahtarları, FILES_NET, FilesTunnel havuzu, STANDBY | 6 | android-client-dev | [T-265, T-266] |
| [T-270](tasks/T-270-wifi-files-device.md) | Cihaz kabulü — Wi-Fi dosyaları (0035): bütçeli ölçüm + Codex --high | 6 | orchestrator | [T-268, T-269] |
| [T-271](tasks/T-271-cursor-probe.md) | Mac probu — yerel imleç: başka uygulamaların imleç şekli, gizli durumu ve değişim maliyeti herkese açık API ile okunabiliyor mu | 6 | mac-host-dev | [] |
| [T-272](tasks/T-272-hidden-cursor-relative.md) | Host — imleç gizliyken göreli hareket imleci kaydırmasın (oyunda Dock/menü çubuğu açılmasın) | 6 | mac-host-dev | [T-271] |
| [T-273](tasks/T-273-usb-tether-probe.md) | Prob — USB tethering (NCM) adb ile başlatılabiliyor mu, uygulama Mac'e bu yoldan ulaşabiliyor mu | 6 | android-client-dev | [] |
| [T-274](tasks/T-274-cursor-protocol.md) | Protocol — local cursor (decision 0036): HELLO bit13, CURSOR_PREFS 0x0B, CURSOR_SHAPE 0x0C, CURSOR_STATE 0x0D | 6 | orchestrator | [T-271] |
| [T-275](tasks/T-275-host-local-cursor.md) | Host — yerel imleç (0036): imleç izleyici, CURSOR_SHAPE/STATE gönderimi, videoda imleci kapatma | 6 | mac-host-dev | [T-274] |
| [T-276](tasks/T-276-client-local-cursor.md) | Client — yerel imleç (0036): imleç katmanı, şekil önbelleği, zaman aşımı geri dönüşü, panel | 6 | android-client-dev | [T-274] |
| [T-277](tasks/T-277-flaky-packed-renderer-test.md) | Client test — PackedRendererTest.directPathNeverCallsAHook ara sıra düşüyor (yarış) | 6 | android-client-dev | [] |
| [T-278](tasks/T-278-cursor-prediction.md) | Client — yerel imleç v2: tablette konum tahmini (göreli hareket + mutlak kalem/dokunma), host durumuyla uzlaştırma | 6 | android-client-dev | [T-276] |
| [T-279](tasks/T-279-audio-silence-gate.md) | Host — tamamen sıfır sesi gönderme (sessizlik kapısı) | 6 | mac-host-dev | [] |
| [T-280](tasks/T-280-hdr-daily-mode.md) | Client — HDR anahtarı Günlük modunda da (mod başına ayrı ayar) | 6 | android-client-dev | [] |
| [T-281](tasks/T-281-hdr-display-p3-primaries.md) | Host — HDR sanal ekranı Display P3 primerleriyle kur (Safari/YouTube HDR) | 6 | mac-host-dev | [] |
| [T-282](tasks/T-282-perf-profile.md) | Ölçüm — tablet ve Mac kaynak profili (boşta / video / oyun), hedefli iyileştirme kartları | 6 | orchestrator | [] |
| [T-283](tasks/T-283-astra-review.md) | Review — gpt-6-astra (high), 2026-10-04 değerlendirmesinden bu yana + riskli dört bölge | 6 | orchestrator | [T-282] |
| [T-284](tasks/T-284-audio-resampler-hot-loop.md) | İstemci — ses örnekleyici sıcak döngüsü (roundToInt yorumlayıcıda; ses çalarken mb-audio %35–39) | 6 | android-client-dev | [T-282] |
| [T-285](tasks/T-285-video-receive-allocations.md) | İstemci — video alma yolunda kare başına ayırmaları azalt (oyunda GC %14, 7 000 fault/s) | 6 | android-client-dev | [T-282] |
| [T-286](tasks/T-286-decoder-loop-wakeups.md) | İstemci — çözücü döngülerinde sabit 4/5 ms yoklama yerine olaya bağlı uyanma (10 fps'te ~950 uyanma/s) | 6 | android-client-dev | [T-282] |
| [T-287](tasks/T-287-audio-idle-pause.md) | İstemci — uzun sessizlikte AAudio akışını duraklat (ses yokken 200 uyanma/s, %2) | 6 | android-client-dev | [T-282] |
| [T-288](tasks/T-288-dav-put-safe-replace.md) | İstemci — WebDAV PUT değiştirmesi başarısız olunca hiçbir sürümü silme | 6 | android-client-dev | [] |
| [T-289](tasks/T-289-hdr-runtime-sdr-fallback.md) | Host — HDR çalışma anı kodlayıcı hatasında SDR'ye düş; pipeline yeniden denemesi tek seferlik kalmasın | 6 | mac-host-dev | [] |
| [T-290](tasks/T-290-test-only-code-cleanup.md) | İstemci — yalnız testte kullanılan üretim kodunu kaldır (FrameQueue.poll, ChromaReuse modelleri) | 6 | android-client-dev | [] |
| [T-291](tasks/T-291-rebuild-budget-with-client-ladder.md) | Host + istemci — tekrarlayan medya hatasında yeniden kurma bütçesini istemcinin kurtarma merdiveniyle birlikte tasarla | 6 | orchestrator | [T-289] |
| [T-292](tasks/T-292-aead-decrypt-copies.md) | İstemci — video kaydı şifre çözmede Conscrypt kopyalarını ve kayıt başına SPI yeniden kurulumunu azalt | 6 | android-client-dev | [T-285] |
| [T-293](tasks/T-293-host-pipeline-breaker.md) | Host — kalıcı medya hatasında devre kesici (video bağlanınca bütçeye sor, bekleme 10/20/30 sn, aynı cihazın oturumunda sıfırlama yok) | 6 | mac-host-dev | [T-291] |
| [T-294](tasks/T-294-client-video-retry-backoff.md) | Tablet — kare gelmeyen video bağlantılarında yeniden açma geri çekilmesi; "manual" durumda 10 sn'de bir kendiliğinden dönüş | 6 | android-client-dev | [T-291] |
| [T-295](tasks/T-295-client-remove-fallback-knobs.md) | Tablet — T-286 `dec_wait poll` ve T-292 `aead_path legacy` yedek yollarını kaldır | 6 | android-client-dev | [T-286, T-292] |
| [T-296](tasks/T-296-perf-baseline-kit.md) | Ölçüm tabanı — tekrarlanabilir sentetik senaryolarla iki tarafın CPU, uyanma, gecikme ve pil maliyeti (kullanıcısız) | 7 | orchestrator | [] |
| [T-297](tasks/T-297-simplification-review.md) | Sadeleştirme incelemesi — alt sistem başına Opus ajanları + gpt-6-astra (high) mimari geçiş + gpt-6.1-sol doğrulama | 7 | orchestrator | [] |
| [T-298](tasks/T-298-optimization-research.md) | Optimizasyon araştırması — gecikme zinciri, kodlayıcı/yakalama ayarları, tablet enerji/CPU, ağ | 7 | orchestrator | [] |
| [T-299](tasks/T-299-host-sleep-participants.md) | Host — uyku katılımcıları hiç kayıt olmuyor; girdi ve ses uyku anında oturum kuyruğundan bağımsız bırakılsın (T-132 eksiği) | 7 | mac-host-dev | [] |
| [T-300](tasks/T-300-client-experiment-leftovers.md) | Tablet — kararı verilmiş deneylerin kodunu kaldır (tos/wifi_ll + Wi-Fi kilidi, hz_pin, renk geçersiz kılma, dec_lowlat/dec_oprate varyantları, VideoTestActivity) | 7 | android-client-dev | [] |
| [T-301](tasks/T-301-client-release-build.md) | Tablet — günlük kullanım için debug olmayan profileable derleme (aynı imza) ve minSdk 31 (karar 0037) | 7 | android-client-dev | [] |
| [T-302](tasks/T-302-host-knob-removals.md) | Host — kapanmış deney anahtarlarını kaldır (BITRATE_STEP + canlı bit hızı zinciri, QUALITY, ENCODER=llrc, REFRESH, WIFI_BITRATE_KBPS, CHROMA 444/sharp_bilinear) | 7 | mac-host-dev | [] |
| [T-303](tasks/T-303-client-dead-code-jitter.md) | Tablet — ölü ve yalnız testte kullanılan kod, sabit titreşim tamponu (FramePacer), API < 31 dalları | 7 | android-client-dev | [T-300] |
| [T-304](tasks/T-304-host-vd-transfer-removal.md) | Host — MATEBRIDGE_VD_TRANSFER anahtarını kaldır (karar 0032 eki); HDR10 aktarım ve primer kurulumu kalır | 7 | mac-host-dev | [T-302] |
| [T-305](tasks/T-305-pen-path-cost.md) | Kalem yolu maliyeti — örnek başına host CPU (~0,6 ms), her örneğin ayrı kayıt olması (max_batch=1), kontrol bağlantısında kuyruk (RTT 108 ms) | 7 | orchestrator | [T-296] |
| [T-306](tasks/T-306-motion-skip-pct.md) | 60 fps içerik 60 Hz panelde %15–35 skip_pct — zamanlayıcı mı, panel mi, ölçüt mü | 7 | orchestrator | [T-296] |
| [T-309](tasks/T-309-host-cursor-sampler-cost.md) | Host — yerel imleç örnekleyicisi her girdi olayında imleç görüntüsünü kopyalayıp hash'liyor; biçim kontrolü yalnız imleç değiştiğinde | 7 | mac-host-dev | [] |
| [T-311](tasks/T-311-host-sharp-chroma-fused-pass.md) | Host — Keskin renk Metal geçişi tek dispatch (HA2), Metal süresi ayrı iz aşaması (HA1), iki Metal geçişinin ortak kurulumu (A8) | 7 | mac-host-dev | [T-302] |
