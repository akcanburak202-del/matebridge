---
id: T-025
title: Faz 2 cihaz doğrulaması — Krita test matrisi, kalem gecikmesi, takılı girdi avı
status: in-progress
phase: 2
owner: orchestrator
depends_on: [T-023, T-024]
decisions: []
files:
  - docs/NOTES.md
  - backlog/tasks/T-025-phase2-device-validation.md
---

## Amaç

PLAN Aşama 2 "Bitti" ölçütünü kullanıcıyla doğrulamak.

## Kabul kriterleri

- [ ] Krita: basınçla kalınlaşan/incelen fırça, eğim (fırça destekliyorsa), hover imleci, silgi (M-Pencil'de varsa), çift dokunma eylemi.
  - Basınç ve hover imleci: **çalışıyor** (kullanıcı, 2026-09-30). Eğim: denenmedi. Çift dokunma: Krita'da fırça değişmiyordu → T-027/T-031 ile düzeldi, **çalışıyor** (kullanıcı, 2026-09-30). Eğim değerleri Krita'ya ulaşıyor (tablet günlüğü xTilt/yTilt ≈ 12–29); fırçada etkisi kullanıcıyla denenmedi.
- [ ] 15 dakikalık serbest çizim: kopuk çizgi yok, takılı kalan tık yok. Arada Wi-Fi kesme / uygulamayı arka plana alma / kablo çekme denemeleri → Mac'te hiçbir düğme basılı kalmaz.
  - **Denenmedi.** Arka plana alma oturumlar arasında birkaç kez oldu, basılı kalan görülmedi (`released=0`), ama çizim ortasında bilinçli deneme yapılmadı.
- [ ] Avuç reddi: kalemle çizerken avuç ekrana değince çizgi bozulmaz.
  - **Çalışıyor** (kullanıcı): el yaslıyken ve çizerken kaldırılınca çizgi kesilmedi.
- [ ] Dokunma: tek dokunuş tık, sürükleme, iki parmak kaydırma.
  - **Çalışıyor** (kullanıcı). İki parmakla yakınlaştırma yok → PLAN Aşama 3'e eklendi.
- [ ] T-022 incelemesinden gelen kontroller: uygulamayı arka plana alıp döndükten sonraki **ilk** dokunuş tık üretiyor (işaretçi kilidi, PROTOCOL §7); kalem ekranda kıpırdamadan dururken çizgi 100 ms'de bir bölünmüyor (canlılık tekrarı `STROKE_START` taşımıyor); parmakla sürüklerken kalem yaklaşınca imleç iki konum arasında zıplamıyor.
  - Arka plandan dönüşte ilk parmak dokunuşu: **tık çalıştı** (kullanıcı). Hareketsiz basılı tutma: geçti (ikinci oturum). Parmakla sekme sürüklerken kalem yaklaşınca: parmak işlevini kaybediyor, kalem devralıyor; iki konum arasında zıplama bildirilmedi. Kalem öncelikli tasarımla (PROTOCOL §7, karar 0006) uyumlu. Kalem yakınlıkta mı yoksa temasta mı devraldığı log'dan ayırt edilemedi (host olay başına log tutmuyor).
- [ ] Kalem gecikmesi: hover/uç ile imleç arasındaki fark (telefon slow-motion ya da log zaman damgaları); gerekirse tablette yerel imleç noktası kararı.
  - Kısmi: USB'de fiziksel temas → Mac olayı medyan 2 ms (girdi yolu). Uçtan uca (görüntü dahil) ölçülmedi.
- [ ] Sonuç tablosu `docs/NOTES.md`'de; kullanıcının kullandığı tasarım uygulamaları varsa onlar da.
  - Ara sonuçlar NOTES 2026-09-30 (iki giriş). Tablo kapanışta.

## Kullanıcı kararları — verildi (karar 0006, 2026-09-30): çift dokunma = fırça/silgi geçişi, çizimde parmak kapalı, yan tuş yok.

### Sorulan sorular

1. Kalemin çift dokunuşu ne yapsın? (ör. silgi/fırça geçişi — Krita'da `E` tuşu; geri al — Cmd+Z; sağ tık; hiçbir şey)
2. Parmakla dokunma: tık/sürükle olsun mu, yoksa çizim uygulamalarında yanlış dokunmayı önlemek için tamamen kapalı mı (ayar)?
3. Kalem yan tuşu (varsa) → sağ tık mı?

## İlerleme (2026-09-30, ilk canlı oturum)

Ayrıntı ve ölçümler: `docs/NOTES.md` 2026-09-30 "Faz 2 ilk canlı deneme" ve "devam".

- **Kurulum çalıştı:** MateBridge.app kendi kimliğiyle Erişilebilirlik izni aldı; sanal ekran vendor/product ile bulundu; tablet ↔ Mac girdi yolu uçtan uca çalışıyor.
- **Bu oturumda çıkan ve kapanan:** kalem örneklerinin öbekli varışı → T-026 (merge edildi; USB'de aralık 2,8 ms, Krita'da köşeler azaldı).
- **Açık sorunlar:**
  1. **"Kalem çizmedi"** (kullanıcı iki kez gördü; biri tuvalin sağ üstünde çizerken). Tekrarlanamadı, log'larda iz yok. 48 temaslık fiziksel temas/alınan vuruş karşılaştırmasında kayıp yok. Bir dahaki sefere olay anında tablet log'u (`adb logcat -d -s MB/input MB/session`) ve host log'u hemen çekilmeli; kalemin çekirdek olayları `getevent -lt /dev/input/event2` ile kaydedilebilir.
  2. **Çift dokunma Krita'da fırça değiştirmiyor** → T-027.
  3. **Wi-Fi'de kalem olayları öbekleniyor** (Krita'da köşeli eğri) → kullanıcı kararıyla PLAN Aşama 5.
  4. Video: Wi-Fi'de ara ara kare atılması (`keyframe_request reason=2`); durağan ekranda bir kez 2,8 sn `decode_ms`. İncelenmedi.
- **Henüz yürütülmeyen adımlar** (T-023 kartındaki 11 adımlık listeden): 1c ve 3 (`--inject-test` ile eğim/silgi fixture'ları), 2 (vuruş ortasında Quit / Ctrl-C / SIGTERM), 4 (sıfır olmayan ve negatif origin), 7 (her release tetikleyicisi gerçek ağda), 8–9 (izin iptali, ekranın düşmesi), 10 (App Nap sonrası watchdog). T-024 kartındaki tablet listesinden: Home/bildirim paneli/kablo çekme vuruş ortasında, harf kutulu (letterbox) koordinat kontrolü.
- **Ölçüm araçları** (repo dışında, oturumun scratch dizininde kaldı; gerekirse yeniden yazılır ya da probe'a taşınması için kart açılır): alınan fare/tablet olaylarını vuruş başına sayan AppKit penceresi (birleştirme açılıştan sonra kapatılmalı) ve `getevent` çıktısını temas satırlarına çeviren betik.

## İlerleme (2026-09-30, ikinci oturum)

- **Vuruş ortasında kablo çekme:** geçti. Host `input_release cause=disconnected pen_up=1 pen_leave=1`; basılı kalan yok. (`input_session_end released=0` sayaç tutarsızlığı not edildi.)
- **Yeni hata:** 10 sn içinde yeniden bağlanınca siyah ekran → T-028. Geçici çözüm: 15 sn bekle.
- Kablo geri takılınca tüneller kendiliğinden gelmiyor (`usb-mode.sh on` gerekir) → Faz 4 notu, NOTES'ta.
- Kalan release denemeleri: Home ve bildirim paneli vuruş ortasında, Wi-Fi kesme, force-stop; hareketsiz basılı tutma (100 ms bölünme), arka plandan dönüşte ilk dokunuş.

## İlerleme (2026-09-30, ikinci oturumun sonu)

- T-028/T-030 (hızlı yeniden bağlanmada siyah ekran): düzeltildi, cihazda 5/5.
- T-029 (tek örneklik temas süzgeci): merge edildi, cihazda yapay kalem olaylarıyla doğrulandı. Krita'daki dikeni **çözmüyor**.
- Krita "diken": ölçüldü (NOTES). "Temel" pürüzsüzleştirmede vuruşların ~%12'si, "Yok"ta 0/120. Olay akışında denenen hiçbir değişiklik gidermiyor. Kullanıcı Krita'da "Yok" ile çalışacak; diğer kipler ölçülmedi (kullanıcı kararı).
- Geçen release denemeleri: kablo çekme, Home, bildirim paneli, hareketsiz basılı tutma.

## Plan

Sıradaki oturum, sırayla: (1) T-027 (çift dokunma Krita'da fırça değiştirmiyor: Krita tablet olay günlüğü, `vendorPointerType` ve benzersiz kimlik denemesi), (2) eğim ve `--inject-test` fixture'ları, (3) uçtan uca kalem gecikmesi, (4) Wi-Fi kesme ve force-stop vuruş ortasında, arka plandan dönüşte ilk dokunuş, (5) 15 dakikalık serbest çizim ("Yok" ayarıyla), (6) sonuç tablosu ve kapanış. Oturum başında: `scripts/usb-mode.sh on`, tablet log ve Mac olay kaydedicisini yeniden başlat (scratch araçları oturumla silinir; tarifleri bellekte).

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
