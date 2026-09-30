---
id: T-057
title: Tablet — sunum zamanlaması düzeltmeleri (yuva başına tek bırakma, son yuvaya gecikme sınırı, faz kalibrasyonu, çözücü doluluğu)
status: todo
phase: 5
owner: android-client-dev
depends_on: [T-052]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/
  - client-android/app/src/test/
  - backlog/tasks/T-057-client-presentation-scheduling.md
---

## Amaç

NOTES 2026-10-01 ~02:20 (ölçüm + gpt-6-astra danışması). Kalan takılma: 120 Hz'te %2,4–4,8 tekrar kare, 60 Hz'te (akış 120) %6–8 33 ms boşluk. Kullanıcı: "akıcı, stutter olmayan görüntü çok önemli".

## Kabul kriterleri

- [ ] **Yuva başına tek bırakma:** `drainOutput`'ta çekilişler arası çarpışma bugün önceki bırakmayı geri alamıyor (yalnızca sayaç). Bir hedef vsync yuvası için en fazla **bir** `releaseOutputBuffer(idx, ns)`; aynı yuvaya düşen daha yeni kare için en fazla **bir değiştirilebilir bekleyen çıkış** tutulur ve ölçülen bir gönderim son anına (deadline) kadar bekletilir; son anda en yeni olan bırakılır, diğeri `releaseOutputBuffer(idx, false)`. Tutulan çıkış arabelleği sayısı sınırlı (en çok 1 bekleyen).
- [ ] **Gecikme sınırı son yuvada:** `AdaptivePacer`'da sınır `D`'ye değil, **nihai sunum yuvasına** uygulanır (en erken olası sunuma göre ≤ 1 vsync + pay); geç kalan kare sonraki boş yuvaya itilmez, daha yeni kare varsa atılır. `D` en çok ~1,5 P (bugün 3P'ye kadar çıkabiliyor).
- [ ] **Faz:** vsync ızgarası `Display.getAppVsyncOffsetNanos()` ve `presentationDeadlineNanos` hesaba katılarak kurulur; `slot − P/2` varsayımı yerine ayarlanabilir bir öncü (lead) sabiti; taban ve jitter hedefi ani değil yumuşak (slew) değişir; boşta kalma ve panel hızı değişiminden sonra yeniden çapalama; faz/periyot tek tutarlı anlık görüntüden okunur, kaçırılan Choreographer geri çağrısı ile gerçek mod değişimi ayırt edilir.
- [ ] **Çözücü doluluğu:** gönderilen − çıkan kare sayısı (`in_codec`) ölçülür ve istatistiğe yazılır; `--ei inflight N` (2/3/4, varsayılan bugünkü davranış ya da ölçüme göre) ile sınır denenebilir; kuyruktaki `held` kare de sayılır.
- [ ] İstatistik: `MB/render` satırına `slot_dups` (aynı yuvaya ikinci bırakma girişimi), `late_drops`, `in_codec_p95`, `lead_ms`.
- [ ] Saf mantık birim testli (yuva seçimi, bekleyen çıkış değişimi, son yuva sınırı, faz yumuşatma, 60/120 Hz ve 120 fps→60 Hz). `./scripts/check.sh` geçiyor.

## Kapsam dışı

- Panel hızını host'a bildirme (T-059). Host (T-058). SurfaceControl. Cihaz ölçümü orkestratörde (SF `--latency`, uzun pencereler).

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
