---
id: T-253
title: Host — "refine when still": after motion stops, send one high-quality frame of the unchanged screen
status: ready
phase: 6
owner: mac-host-dev
depends_on: []
decisions: [0033]
files:
  - host-mac/Sources/
  - host-mac/Tests/
  - backlog/tasks/T-253-host-static-refinement-frame.md
---

## Amaç

Kullanıcı onayladı (2026-10-05): ekran durunca yazı/ikonlar netleşsin. Hareket sırasında bit hızı aynı kalır; hareket bitip ekran durağanlaşınca host son içeriği bir kez çok daha yüksek kalitede kodlar (Parsec/RDP "progressive refinement" benzeri). T-249: tablet çözücüsü 150 Mbps eşdeğeri büyük kareleri ~+2 ms ile çözüyor; IDR ~+15 ms. 4:4:4 çalışmasıyla (docs/research/2026-10-05-yuv444-packing.md §6 "yardımcı yalnız durağanken") ileride birleşebilir; bu kart yalnız 4:2:0 kalite iyileştirmesi.

## Bağlam

- **Önce tasarım (Plan bölümünde, kod öncesi commit):** SCK değişiklik yokken kare göndermiyor; durağanlık nasıl algılanır (son kareden beri T ms yeni kare yok; önerilen ~150–300 ms), hangi VT yolu yüksek kaliteli tek kare verir (geçici `Quality`/`AverageBitRate`/`DataRateLimits` değişimi + aynı pikselleri yeniden kodlama; ya da zorunlu IDR; VT'nin oturum içi özellik değişikliğinin gecikme/yan etkisi ölçülsün), son yakalanan `CVPixelBuffer`'ın güvenle tutulması (SCK havuz ömrü), sonraki normal karede bit hızının eski hale dönmesi, hız denetiminin (LLRC/fast profil, 120 fps'te `.fast`) bozulmaması.
- Kısıtlar: yeni kare sıradan bir kare olarak gider (tel biçimi DEĞİŞMEZ; istemci değişikliği gerekmemeli: yeni `frame_seq`, yeni zaman damgası). Hareket yeniden başlarsa iptal/önceliksiz. Boyut sınırı: tek kare için üst bayt sınırı; Wi-Fi'da (taşıma bilgisi host'ta varsa) daha küçük sınır ya da kapalı — patlama Wi-Fi'da ses/girdi gecikmesi yapıyordu (NOTES T-126). DISPLAY_RATE/boşta karartma (0031, T-234: karartma kare akışına bakıyor mu?) ve HDR (0032), keskin renk (0033) ile etkileşim incelensin.
- Düğme: `MATEBRIDGE_REFINE=0` kapatır; `MATEBRIDGE_REFINE_MS`, `MATEBRIDGE_REFINE_KB` ayarlar. Log: `ev=refine bytes= enc_ms= quality=`.
- Mac'te pencere açma; birim testleri durağanlık zamanlayıcısı ve karar mantığı için. Cihaz testi orkestratörde.

## Kabul kriterleri

- [ ] Plan (tasarım) önce commit; sonra uygulama.
- [ ] Durağanlıktan sonra tek yüksek kaliteli kare; hareket varken hiç; varsayılan açık ya da kapalı önerisi gerekçeli.
- [ ] Birim testleri; `./scripts/check.sh` geçer.
- [ ] Handoff: cihazda doğrulama (yazı netliği öncesi/sonrası, `ev=refine` boyutları, tablet `dec_*` ve gecikme, Wi-Fi'da ses kesintisi yok).

## Plan

**Ölçüm (CLI VT bench, 2800x1840 HEVC Main, HW, `.fast` profili, RealTime kapalı, kaydırılan yazı + gürültülü fotoğraf alanı, kodlayıcı çıktısı VT ile çözülüp luma PSNR'ı alındı):**

- Oturum içi `Quality`, `MaxAllowedFrameQP`, `AverageBitRate`/`DataRateLimits` (x8, x20) değişikliği tek karede HİÇ etki etmiyor: aynı pikselleri yeniden kodlayan P karesi birebir aynı bayt sayısı ve PSNR veriyor (37 473 B, 38.34 dB). `Quality` oturum açılırken verilse bile HW HEVC'de yok sayılıyor (bayt bayt aynı). Yani "geçici kalite yükselt + tek kare" yolu çalışmıyor.
- Zorunlu IDR: 20 Mbps'te 1.16 MB (36.97 dB, hareketli zincirden DAHA kötü), 60 Mbps'te ~1.9 MB; bit hızı değişikliği IDR'yi de etkilemiyor. Tablette ~+15 ms çözme. Kötü yol.
- Etkili olan: SON YAKALANAN tamponu art arda normal P kareleri olarak yeniden kodlamak. Kodlayıcı her karede referansa kalan kuantalama hatasını biraz daha kodluyor ve yakınsıyor: 20 Mbps'te 38.09 -> 41.13 dB (+3.0), 60 Mbps'te 45.6 -> 47.64 dB (+2.0); 12-14 karede yakınsıyor (kare boyutu < 1.5 KB), toplam ~360-430 KB, her kare ~6 ms kodlama. Sonraki gerçek kare normal P (kaliteli referanstan), bit hızı ayarı hiç değişmediği için "geri alma" gerekmiyor, hız denetimi/profil (LLRC/fast) dokunulmuyor.

**Tasarım (tek kare yerine kısa "tren": N özdeş P karesi; tel biçimi değişmez, her biri sıradan kare):**

1. Durağanlık: `HEVCEncoder.encode` (her gerçek SCK karesi) politikaya `noteCapture` der. Son gerçek kareden `stillMs` (varsayılan 200 ms) sonra, yeni gerçek kare yoksa ve çıkış kuyruğu boşsa tren başlar. 25 ms'lik bir zamanlayıcı yalnız ilk kareyi başlatır; sonraki kareler önceki karenin kodlama çıktısıyla tetiklenir (pacer kapısı karelerin hızını stream fps'te tutar, patlama yok).
2. Tutulan tampon: kodlayıcı zaten son tamponu `EncoderSubmitOrder.last` içinde tutuyor (T-086 resubmitLast, idle keyframe); yeni bir tutma yok, SCK havuz ömrü etkilenmez (queueDepth 5 > 2 + 1 tutulan).
3. Bitiş: (a) yakınsama (kare <= 1.5 KB), (b) en çok 16 kare, (c) tren bayt tavanı (`MATEBRIDGE_REFINE_KB`; USB 1024 KB, Wi-Fi 256 KB), (d) yeni gerçek kare = iptal (öncelik harekette; bekleyen refine karesini pacer zaten ezer), (e) çıkış kuyruğu dolu = dur (kuyruk taşması "frame drop -> IDR" zincirini tetikler, bu yüzden her kareden önce kuyruğun boş olması şart), (f) 250 ms çıktı gelmezse zaman aşımı. Hiçbir kare sonradan atılmaz: hepsi geçerli P karesi, referans zinciri bozulmaz (tek büyük kareyi atmak zinciri bozardı).
4. Tekrar: tren bittikten sonra yeni bir gerçek kare gelmeden yeni tren yok; iki tren başlangıcı arası en az 500 ms (ekranda saniyelik saat gibi küçük değişimler sürekli tren üretmesin; yakınsamış ekranda tren 1 karede biter).
5. Etkileşimler: boşta karartma tablette (0031) ve akışa bakmıyor, karartılmış ekranda tren zararsız (tek sefer). DISPLAY_RATE: kapı `min(fps, hz)`'e uyar. HDR10/keskin renk: aynı yeniden kodlama yolu; keskin renkte her tren karesi Metal geçişinden geçer (~2.5 ms GPU x en çok 16). Tren, bekleyen keyframe isteğini normal kare gibi tüketir (yeni tüketici zaten kendi keyframe'ini resubmitLast ile ister).
6. Varsayılan AÇIK (bedel sınırlı: toplam bayt tavanı, hareket yokken, yalnız boş kuyrukta; tel/istemci değişmez; `MATEBRIDGE_REFINE=0` ile kapanır). Cihaz doğrulaması orkestratörde.
7. Kod: Core'da saf `StillRefineConfig` (env + taşıma) ve `StillRefinePolicy` durum makinesi (birim testli); host'ta `HEVCEncoder` yapıştırması (zamanlayıcı, `resubmitLast(refine:)`, çıktı bayt bildirimi), `VideoFrameQueue.isReadyForRefine`, `VideoPipeline`/`StreamCoordinator` bağlantısı (taşıma bilgisi), log `video ev=refine frames= bytes= first_bytes= last_bytes= ms= reason=` (tren başına bir satır; `quality=` alanı yok çünkü kalite düğmesi etkisiz, bkz. ölçüm).

## Handoff

## Open questions
