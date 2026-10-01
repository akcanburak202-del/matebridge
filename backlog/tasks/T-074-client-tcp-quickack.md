---
id: T-074
title: Tablet — USB (adb) tünelinde 40 ms paketlemeyi kır: alma soketinde TCP_QUICKACK
status: todo
phase: 5
owner: android-client-dev
depends_on: [T-073]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/
  - backlog/tasks/T-074-client-tcp-quickack.md
---

## Amaç

Kare izi (T-073) + host CSV (2026-10-01 12:45, USB modu, 60 fps): host kareleri düzenli 16,6 ms arayla gönderiyor (`write_done` aralığı), ama tablette `recv_ns` bazı dönemlerde **40 ms, 0, 40, 0…** (iki kare birlikte) geliyor. Host ve tablet soketlerinde `TCP_NODELAY` açık; aradaki adbd'nin yerel soketi (tablette adbd → uygulama, loopback) büyük olasılıkla Nagle kullanıyor ve uygulama tarafındaki Linux gecikmeli ACK'i (en az 40 ms) onu kilitliyor. Düzeltme: uygulamanın alma soketinde `TCP_QUICKACK` (Linux, seçenek 12, `IPPROTO_TCP`); kalıcı değildir, her `read()` sonrası yeniden kurulmalı.

## Kabul kriterleri

- [ ] Video (ve kontrol) soketinde, her başarılı okuma sonrası `Os.setsockoptInt(fd, IPPROTO_TCP, 12 /*TCP_QUICKACK*/, 1)`; fd `ParcelFileDescriptor.fromSocket` ya da eşdeğeriyle (soket sahipliğini bozmadan; `dup` edilmiş fd'yi sızdırma). Hata olursa bir kez logla ve devre dışı bırak (oturumu bozma).
- [ ] Deney anahtarı `--ez quickack false` (varsayılan **açık**), `ev=display_timing` ya da oturum satırında `quickack=0|1`.
- [ ] Ek yük: okuma başına bir sistem çağrısı; okumalar zaten kare başına birkaç tane. Gerekirse yalnızca USB modunda açılabilir — seçimini gerekçelendir.
- [ ] Test (anahtar ayrıştırma; setsockopt sarmalayıcısı sahte ile). `./scripts/check.sh` geçiyor.

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
