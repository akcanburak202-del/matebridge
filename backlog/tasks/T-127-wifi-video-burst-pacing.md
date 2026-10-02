---
id: T-127
title: (İleride) Wi-Fi — büyük video patlamalarının sesi geciktirmesi; bit hızı / gönderim hızı sınırı / Ethernet ile yeniden değerlendir
status: todo
phase: 5
owner: orchestrator
depends_on: [T-126]
decisions: []
files:
  - backlog/tasks/T-127-wifi-video-burst-pacing.md
---

## Amaç

**Kullanıcı kararı (2026-10-02):** "şimdilik Wi-Fi modu idare eder, mükemmel olmasına gerek yok; ileride tekrar inceleriz." Bu kart o not.

Bulgu (NOTES 2026-10-02 ~13:20):
- Wi-Fi'de tam ekran değişimlerinde (pinch, uygulama değiştirme) video 100–450 KB'yi tek seferde havaya veriyor; `snd_cwnd` sınırsız büyüyor (2–13 MB).
- Kablosuz kuyruk dolunca ses de (ayrı TCP, AC_VO) 60–100 ms gecikiyor ve alt taşma oluyor. 5 dk'da 13; T-125 sayesinde hemen toparlanıyor.
- USB'de sorun yok.

Denenecekler (sırayla):
1. Mac'i Ethernet'e bağla (kullanıcı uygun zamanda deneyecek) ve aynı testi tekrarla: `ev=tcp` ile kontrol `srtt` ve alt taşma sayısı.
2. Panelden Wi-Fi bit hızını düşür (örneğin 30 Mbps) ve karşılaştır.
3. Gerekirse host kartı: Wi-Fi'de video soketinde havadaki veriyi / gönderim hızını sınırla (pacing, `TCP_NOTSENT_LOWAT` + uygulama düzeyinde bayt bütçesi), gecikme ve keskinlik etkisini ölç.
4. Son çare: Wi-Fi ses payını ~100 ms'ye çıkarmak.

## Plan

_(Değerlendirme zamanı gelince.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
