---
id: T-313
title: Host — ölü ve yalnız testte kullanılan kod, küçük tekrarlar, test kopyaları (T-297 parti 4) ve REFINE anahtarları ev=profile'da
status: review
phase: 7
owner: mac-host-dev
depends_on: [T-302, T-304, T-309, T-311]
decisions: []
files:
  - host-mac/Sources/
  - host-mac/Tests/
  - backlog/tasks/T-313-host-dead-code.md
---

## Amaç

T-297 parti 4 (`docs/reviews/2026-10-08/simplification.md`). Kanıtlar (dosya:satır; T-302/T-304/T-309/T-311 sonrası kaymış olabilir, okuyarak doğrula):
- `docs/reviews/2026-10-08/agents/simp-a-host-video.md`: A2, A3, A4, A5, A6, A7, A9, A13;
- `simp-b-host-session.md`: B2, B3, B6 (ölü kısımlar ve kopya temizlik; dinleyici birleştirmesi **hariç**), B8, B10, B11, B12;
- `simp-e-protocol.md`: E5, E7, E8 (Swift kısmı), E11.

## Kabul

1. **Ölü ve test-yalnız kod:** A3, B10 ve E5 listeleri silinir. A5 testleri üretim API'lerine geçer. A9 CPU referans modelleri (`SharpYUV` CPU dönüşümü, `AVC444v2` paketleme) test hedefine taşınır; üretimde yalnız sabitler, doğrulayıcılar ve kernel kaynakları kalır.
2. **Sıcak yol, davranış aynı:**
   - **A2+A7:** kodlanmış kare tek kopyayla Annex-B'ye; 4 baytlık uzunluklar yerinde başlangıç koduna çevrilir. Çok parçalı `CMBlockBuffer` yolu ve bozuk girdi kontrolleri kalır. Yeni test, eski `AnnexB.convert` ile bayt bayt eşitliği gösterir. Son `CMFormatDescription` önbellekte tutulur; aynı nesnede VPS/SPS/PPS yeniden çıkarılmaz, CODEC_CONFIG duyurusu her değişimde gider.
   - **A6:** kare başına renk etiketleri Core sabitinden.
   - **A13:** `mach_timebase_info` önbellekte.
3. **Tekrarlar ve yapı:**
   - A4 `VideoSender` tek yazma yolu.
   - B2 `nw` artıkları; B3 türetme yardımcısı (`session_without_config` ölü dalı).
   - B6 ölü parçalar ve 6 haritalı kopya temizlik.
   - B8 tek en-son-değer posta kutusu.
   - B12 `.teardown(reason)`.
   - E7 Ping/Pong/Stats/VideoHello struct üstüne, `SessionServer` VIDEO_HELLO için `Message.decode`.
   - E11 `SessionMachine` satır içi eşleşme anahtarı yolu kalkar; testler async yola geçer.
4. **Testler:** B11 kopya lease testleri silinir; lease paketi `DisplayLeaseTests.swift`'e taşınır.
5. **`REFINE`:** `MATEBRIDGE_REFINE`, `_MS`, `_KB` ve `_FRAMES` `StreamProfileLog.knobAllowList`'e eklenir (KNOBS açık nokta 3).
6. **Değişmeyenler:** protokol baytları (fixture testleri), girdi güvenliği yolları, `EncoderSubmitOrder` tek sahip ve `VirtualDisplay` yalıtımı.
7. **Handoff:** silinen satır sayısı ve gerekirse LOGGING önerisi. Cihaz kontrolü orkestratörde (Keskin renk, Tam renk, HDR açılışı, yeniden bağlanma).

## Plan

Dört mantıksal grup, her biri ayrı commit: (1) ölü/test-yalnız kod + CPU referanslarını test hedefine taşı; (2) sıcak yol (tek kopya Annex-B, biçim tanımı önbelleği, renk etiketi, timebase); (3) tekrarlar ve yapı (VideoSender, nw artıkları, posta kutusu, lease neden, lease testleri); (4) E7 yapılar, REFINE anahtarları. Her maddeyi güncel kodu okuyarak doğruladım; güvenli olmayan veya artık geçerli olmayanları atladım (Handoff).

## Handoff

- Commit'ler (task/T-313-host-dead-code): `79331853` (A3, A5, A9, B10, E5), `2befb700` (A2, A6, A7, A13), `ed456f0a` (A4, B2, B3, B6, B8, B11, B12), `25948999` (E7, REFINE); kart güncellemesi son commit.
- Satır sayısı (c14d8220..HEAD): Sources +358 / -783 (net -425), Tests +575 / -284 (Tests'in artısı ~330 satır taşınan CPU referansları: `SharpYUVReference.swift`, `PackedChromaReference.swift`). Toplam 52 dosya, +933 / -1067.
- `./scripts/check.sh`: ALL OK (host 1033 test, android, protocol, vectors).
- Yapılanlar: A3 (ölü API'ler, yanlış yerdeki doc), A5 (`VideoFrameQueue` test-yalnız aşırı yüklemeler: `resync(config:)` x2, `startNewConsumer(config:)`, `hasFrames`, `peek`; testler `resyncCountingKeyframes`, `startNewConsumer(configProvider:)`, `tryPop` kullanır), A9 (`SharpYUV` ve `AVC444v2` CPU referansları test hedefine; üretimde `Upsample`, EOTF tablosu, `isValid`, kernel kaynakları), A2+A7 (`AnnexB.convertInPlace` + `HEVCEncoder.annexBPayload`/`isKeyframe` ortak, `ParameterSetCache` biçim nesnesi kimliğine göre; CODEC_CONFIG hâlâ blob her değiştiğinde gider; yeni test eski `convert` ile bayt bayt eşit, bozuk/kesik/bozulmuş girdi ve 1-4 uzunluk boyutu), A6 (`SessionColorTags.tags`), A13 (timebase önbelleği, `PackedMonitorBox` döngüsüz), A4 (`run()` artık `write()` kullanır), B2 (`TcpSocketProbe` sınıfı, `SendQueueSource`, `TcpSample` isteğe bağlı alanları, `VideoSocketSettings` kalktı; log çıktısı bayt bayt aynı, sabit `source=tcp_info`, `video_socket=bsd`, `control_socket=bsd` korunuyor), B3 (`derive(...)` yardımcısı, ölü `session_without_config` dalı ve isteğe bağlı olay alanları), B6 (`defaultStreamConfig`, `VideoLink.onReady`/kilit, `closeVideo` sarmalayıcısı, 5 haritalı temizlik tek `dropControlState`), B8 (tek `EpochCoalescer`: `CursorPrefsMailbox` ve `LatestValueSlot` silindi, kuralları `EpochCoalescerBoundaryTests`'e taşındı), B10 (isHeld, FilesSocket.isClosed, heldModifierKeys, Placeholder.swift, isInGrace, defaultGraceUs türetilmiş, UsbTunnelWatcher takma adları, CursorStats döngüleri, AppDelegate.log artık `HostLog`: ayrıca `host.log` dosyasına da yazılır), B11 (iki kopya test silindi, lease paketi `DisplayLeaseTests.swift`'te), B12 (`.teardown(reason)`), E5 (penSampleSize/penFixedSize, isPacked444, isEncrypted, CursorState.size), E7 (Ping/Pong/Stats/VideoHello `write/read` yapıları üzerinde; `SessionServer` VIDEO_HELLO için `Message.decode`), REFINE x4 `knobAllowList`'te (+ test).
- Atlananlar ve nedeni:
  - **E11** (`SessionMachine` satır içi `pairKeys` yolu): test-yalnız evet, ama ~190 `received(` çağrısı / 10 test dosyasına yayılıyor (el sıkışma güvenliği testleri); mekanik olmayan toplu düzenleme riski değerine göre yüksek. Ayrı kart öneririm.
  - **B2 kısmen**: sabit log alanları (`video_socket=bsd`, `control_socket=bsd`) log ayrıştırıcıları için bilerek korundu (LOGGING.md bunu söylüyor).
  - **B3**: `parseRefreshHz` x5 / REFRESH x7 T-302'de zaten kalkmış; `stream_prefs` log'undaki 60 sorunu artık yok.
  - **B6**: `LockedSet/LockedValue/OnceFlag -> Mutex` ve `startVideoListener/startControlListener` birleştirmesi yapılmadı (kartın "ölü parçalar ve 6 haritalı kopya temizlik" kapsamı dışı sayıldı).
  - **B10**: `adb devices` dizisi tekrarı (`TabletFilesBridge` / `UsbTunnelWatcher.tick`) birleştirilmedi: iki yerde başarısızlık nedenleri (`no_adb_server`/`no_device`) farklı, ortak yardımcı üç yönlü sonuç ister, kazanç küçük.
  - **A13**: "meter optional-but-always" yapılmadı (gözlem sarmalayıcısı, davranış riski).
  - **B2/B6 `BoundedFrameQueue.resync`**: üretimde `VideoFrameQueue.resyncCountingKeyframes` çağırıyor, test-yalnız değil; kaldı.
- Varsayımlar: `CMFormatDescription` aynı nesne kimliği (`===`) parametre kümelerinin değişmediği anlamına gelir; `lastParameterSets` hiçbir yerde sıfırlanmadığı için güvenli. `AnnexB.convertInPlace` lengthSize != 4 için `convert`'e düşer.
- Gerçek donanımda doğrulanacak (orkestratör): Keskin renk, Tam renk (packed444, aux CODEC_CONFIG view=1), HDR açılışı, yeniden bağlanma (VIDEO_HELLO yolu `Message.decode`), imleç ayarı (CURSOR_PREFS epoch posta kutusu), pano gelen metin, bir oturum kapat/aç (park/teardown reason log'u `ev=display_teardown reason=`), `ev=profile knobs=` satırında REFINE.
- Öneri: LOGGING.md/KNOBS.md (kapsam dışı): KNOBS açık nokta 3 kapandı (REFINE* artık `knobs=`'ta), `ev=app` onay log'ları (`approval_shown/disconnected/dismissed`) artık `host.log` dosyasında da görünür.

- Review round 1 (Codex P2): `ClipboardBridge.drainIncoming` looped, so an update arriving during `applyIncoming` also queued a redundant block. Now each scheduled block takes exactly one value (at most one running and one waiting); a coalescer test covers it. The cursor-prefs user is unchanged (it already takes once per wake).

## Open questions

- E11 ayrı karta alınsın mı (test sitelerinin mekanik dönüşümü)?
