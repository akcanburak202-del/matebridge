# 0014 — Oyun modu: 120 fps, %66, en düşük gecikme; geçici varsayılanlar

- **Durum:** kabul
- **Tarih:** 2026-10-02

## Bağlam
Kullanıcı Witcher 2'yi oynarken (T-103 sonrası) oyunlara özel bir mod istedi: en yüksek fps, çok akıcı. Akıcı mod (120 fps, tam boyut) "gayet iyi", ama ayrı bir mod istendi. Tabletin paneli fiilen 144 Hz'e çıkmıyor (T-050), bu yüzden üst sınır 120 fps.

Kullanıcı seçimleri (2026-10-02):
- çözünürlük %66;
- öncelik en düşük gecikme (kusursuz akıcılık değil);
- ek varsayılanlar: yüksek bit hızı, ses "Düşük gecikme", kalem izi/noktası kapalı.

Kullanıcının sözü: "bu ayarlar otomatik oyun modu ile gelsin ama kalıcı olmasın, yani oyun modu sonrası bunları değiştirebilelim, yani bunlar bir nevi varsayılan ayar gibi olsun".

## Karar
1. **Yeni görüntü modu "Oyun":** `STREAM_PREFS` fps `120`, `scale_permille` `660`. Protokol değişmez. Mod döngüsüne (Ctrl+Shift+7) ve panellere eklenir.
2. **En düşük gecikme:** oyun modunda istemci video jitter tamponu 0'dır (`bufferFrames = 0`). Gelen kare beklemeden bir sonraki vsync'e verilir; uyarlamalı oynatma gecikmesi uygulanmaz. Diğer modlar değişmez.
3. **Geçici varsayılanlar (oturum katmanı):** oyun moduna girince üç ayar oyun varsayılanına çekilir. Bunlar kullanıcının kayıtlı ayarlarının **üstüne binen geçici değerlerdir**:
   - bit hızı: Otomatik seçiliyse 60 Mbps;
   - ses çıkışı: Düşük gecikme;
   - kalem izi/noktası: kapalı.

   Kurallar:
   - Oyun modu açıkken kullanıcı bu ayarları panelden değiştirebilir. Değişiklik yalnızca o oyun modu süresince geçerlidir ve kayıtlı ayarlara yazılmaz.
   - Oyun modundan çıkınca kayıtlı ayarlar aynen geri gelir.
   - Bir sonraki girişte oyun varsayılanlarıyla yeniden başlanır.
   - Uygulama yeniden açılırsa ve kayıtlı mod Oyun ise, oyun varsayılanlarıyla başlar.
4. Panelde oyun modu açıkken bu üç ayarın yanında "(oyun modu)" gibi bir işaret görünür; kullanıcı neden farklı olduklarını anlar.

## Sonuçlar
- Kart T-109 (tablet).
- Host'ta değişiklik gerekmez: 120 fps, %66 ve 60 Mbps mevcut `STREAM_PREFS` aralığında.
- Tekrar düşünülür:
  - jitter 0'da takılma görülürse (o zaman 1 kare tampon);
  - Wi-Fi'de 60 Mbps sorun çıkarırsa (o zaman taşımaya göre varsayılan).
