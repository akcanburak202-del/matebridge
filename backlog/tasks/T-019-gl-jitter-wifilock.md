---
id: T-019
title: Akıcılık — GL yolunda titreşim tamponu ve Wi-Fi düşük gecikme kilidi
status: todo
phase: 1
owner: android-client-dev
depends_on: [T-018]
decisions: [0004]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/AndroidManifest.xml
  - client-android/app/src/test/kotlin/dev/matebridge/client/
---

## Amaç

Mac 60,0 fps düzenli gönderiyor (T-017). Tablet 60 Hz'e kilitli (HarmonyOS, hem video hem GL yüzeyi). GL yolunda ölçüm: 61 vsync'te 48–59 kare çiziliyor, boş vsync'ler kareler birkaç ms geç geldiği için. Kullanıcı hâlâ takılma görüyor. Hedef: 60 fps içerikte her vsync'te tam bir kare, titreşim ~16 ms'ye kadar emilsin.

## Kabul kriterleri

- [ ] **GL titreşim tamponu:** GL yolunda hazır kareler küçük bir kuyrukta (en çok 3) tutulur. Her vsync'te tam bir kare çizilir. Tampon hedefi `--ei gljitter 0|1|2` (varsayılan 1): kuyrukta hedeften fazla kare birikirse en eskiler atlanır (en yeni kazanır, gecikme sınırlı), boşsa son kare tekrar çizilir ve "underrun" sayılır. `updateTexImage` sırası ve SurfaceTexture tek-tampon kısıtı doğru ele alınır (gerekirse ImageReader/çoklu doku ya da kare kopyası; gerekçe Handoff'ta).
- [ ] Saniyede bir `gl_stats`: çizilen yeni kare, tekrar çizilen (underrun), atlanan, kuyruk derinliği ortalama/maks., eklenen bekleme ms.
- [ ] **Wi-Fi düşük gecikme:** akış sırasında `WifiManager.createWifiLock(WIFI_MODE_FULL_LOW_LATENCY)` (API 29+) alınır, akış bitince bırakılır. Alınıp alınmadığı ve modun etkin olup olmadığı loglanır. Anahtar: `--ez wifilock true|false` (varsayılan true). Gerekli izin manifestte.
- [ ] Ağ varış aralığı p95/p99 ve geç varış sayısı zaten loglanıyor (T-016); wifilock açık/kapalı karşılaştırılabilir olsun.
- [ ] `./scripts/check.sh` geçiyor.

## Notlar

- Orkestratör karşılaştırması: `render=gl gljitter=0/1/2`, `wifilock=true/false`, Wi-Fi ve USB, kullanıcı gözüyle.
- Gecikme bütçesi: gljitter=1 en fazla ~17 ms ekler.

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
