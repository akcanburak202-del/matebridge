---
id: T-119
title: Host — ses tap'i oluşturulamazsa (oturum devri yarışı) kalıcı vazgeçme; kısa gecikmeyle yeniden dene
status: todo
phase: 5
owner: mac-host-dev
depends_on: []
decisions: [0011]
files:
  - host-mac/Sources/MateBridgeHost/Audio/
  - host-mac/Sources/MateBridgeCore/Audio/
  - host-mac/Tests/MateBridgeCoreTests/
  - backlog/tasks/T-119-host-audio-tap-create-retry.md
---

## Amaç

Cihazda görüldü (2026-10-02 ~10:20). APK kurulumundan sonra tablet 0,4 s içinde iki kontrol bağlantısı açtı ve oturum devri (takeover) oldu:

```
audio_stopped stream_id=3 reason=session_end
session_superseded conn=8
session_started conn=11
audio_capture_stopped stream_id=3
(1,1 s sonra) audio_unavailable reason=tap_create status=0 stream_id=4
```

- `AudioHardwareCreateProcessTap` `noErr` döndürdü ama `tapID` `kAudioObjectUnknown` kaldı. Büyük olasılıkla önceki tap/aggregate henüz sökülürken yeni tap istendi.
- `SystemAudioTap.build` içindeki `fail` bu isteği kalıcı bırakıyor ("never rebuilt by a later pass").
- Sonuç: oturum boyunca ses tablete gitmedi. Mac'in kendi hoparlöründen çaldı, kullanıcı fark etti. Ancak yeni bir oturum düzeltti.

## Kapsam dışı

- Tablet tarafının çift bağlantı açması (ayrı konu; Açık sorular'a not edilebilir).
- Ses biçimi/yakalama mimarisi.

## Kabul kriterleri

- [ ] `tap_create` / `aggregate_create` geçici hataları (status hata ya da `noErr` + bilinmeyen ID) sınırlı yeniden denemeye girer: örneğin 3–5 deneme, artan gecikme (100 ms → ~1 s). İstek o arada iptal edildiyse (oturum bitti, `desired` değişti) deneme yapılmaz. Kalıcı hatalar (`no_output_device`, desteklenmeyen biçim) bugünkü gibi hemen vazgeçer; Plan'da sınıflandırma yazılır.
- [ ] Yeniden kurulumdan önce önceki çalışmanın sökümü tamamlanmış olur (aynı kuyrukta sıralı). Yarışın kaynağı Plan'da açıklanır.
- [ ] Log: her deneme için `ev=audio_retry reason= attempt= delay_ms=`. Son başarısızlıkta bugünkü `audio_unavailable` satırı.
- [ ] Mevcut `AudioStreamer` yeniden kurma politikasıyla (`retryDue`) çakışmaz; mümkünse o politika yeniden kullanılır.
- [ ] Deneme/sınıflandırma mantığı Core'da, birim testli: geçici hata → başarılı deneme; iptal edilen istek; kalıcı hata.
- [ ] `./scripts/check.sh` geçiyor. Cihaz testi (hızlı yeniden bağlanma) orkestratörde.

## Plan

_(Ajan kodlamadan önce doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
