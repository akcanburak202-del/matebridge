# 0043 — Touchpad'de üç parmak kaydırma → Mac sistem kısayolları

- Tarih: 2026-10-25
- Durum: kabul (kullanıcı onayı 2026-10-25: "evet böyle yapalım")

## Bağlam

Kullanıcı Mac'e yeni alışıyor. Gerçek Mac trackpad'inde üç parmakla yukarı kaydırma Mission Control'ü açar, sağa/sola kaydırma masaüstleri arasında geçiş yapar. MateBridge'de Glide Keyboard touchpad'inden bu hareketler Mac'e gitmiyor (bugün üç parmak `locked`: hiçbir şey göndermiyor). Dock kaydırma hareketini (`NSEventTypeGesture` alan tabanlı) dışarıdan üretmek macOS 27'de bozuk (NOTES 2026-09-30, Mac Mouse Fix #1876). Yakınlaştırma (karar 0009) çalışıyor, Dock kaydırma çalışmıyor.

Ayrıca tablet klavyesinde Ctrl → Command (karar 0008), bu yüzden kullanıcı Control+ok kısayollarını klavyeden de basamıyor.

## Karar

1. Yeni mesaj **0x18 PAD_SWIPE** (C→H), PROTOCOL §4. İstemci touchpad'de üç parmakla yapılan kaydırmayı tanır ve hareket başına en çok bir mesaj gönderir.
2. Host bunu **kısayol** olarak enjekte eder, hareket olarak değil: yukarı → Control+↑ (Mission Control), aşağı → Control+↓ (Uygulama pencereleri), parmaklar sola → Control+→, sağa → Control+← (gerçek trackpad yönleri). Basış tek parça (bas + bırak) enjekte edilir, mesajlar arasında basılı durum kalmaz.
3. Bütün modlarda (Günlük, Çizim, Oyun) ve uzak oturumda açık. Hareket yalnız touchpad'den gelir, kalemle çakışmaz. Ayar anahtarı yok (minimal arayüz, 0028/T-352). İstenirse sonra eklenir.
4. Dokunmatik ekranda üç parmak bu kararın kapsamı dışında (Huawei'nin üç parmakla ekran görüntüsü hareketiyle çakışır).

## Sonuçlar

- Geçiş parmağı adım adım izlemez. Hareket tanınınca animasyon bir kerede oynar.
- Kullanıcı Mission Control kısayollarını Sistem Ayarları'nda kapatır ya da değiştirirse hareket o kısayolu izler.
- Risk: sentetik Control+ok olayının sistem kısayolunu tetiklemesi için ok tuşlarında `maskSecondaryFn | maskNumericPad` bayrakları gerekebilir. Bu cihazda doğrulanır (T-375).
- Risk: HarmonyOS üç parmak touchpad olaylarını uygulamaya iletmeyebilir. NOTES T-003'te pointer capture altında iki parmak görüldü, üç parmak denenmedi. T-376 debug logu ile doğrulanır.
