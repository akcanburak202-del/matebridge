# 0006 — Faz 2 girdi davranışı: çift dokunma, parmak dokunması, yan tuş

- **Durum:** kabul
- **Tarih:** 2026-09-30

## Bağlam
Faz 2 başlamadan kullanıcıya üç tercih soruldu (T-025).

## Karar
1. **Kalemin çift dokunuşu = fırça/silgi geçişi.** Uygulamadan bağımsız yöntem: host, `PEN_GESTURE DOUBLE_TAP` aldığında kalem için "silgi modu"nu açıp kapatır. Silgi modunda kalem Mac'e **silgi ucu** olarak bildirilir: tablet proximity `pointerType = eraser`, araç değişiminde §4 kuralı (up gerekirse + leave + yeni araçla enter). Krita/Photoshop gibi uygulamalar silgi ucunu kendiliğinden silgiye çevirir. Mod oturum boyunca kalıcıdır. Oturum biterse veya release-all olursa kalem moduna döner.
2. **Parmakla dokunma çizim sırasında kapalı.** Kalem `IN_RANGE` iken ve son kalem örneğinden sonraki **1 sn** boyunca yeni parmak basışları gönderilmez (istemcide) ve yok sayılır (host'ta, §7). Bırakışlar her zaman işlenir. Ek olarak tablette "Parmak dokunmasını tamamen kapat" ayarı olur (varsayılan: kapalı değil).
3. **Kalem yan tuşu yok** (M-Pencil 3). `PEN.flags.BUTTON` protokolde kalır ama eşlenmez.

## Sonuçlar
- Çift dokunma için uygulamaya özel kısayol gerekmez. Tabletin kendi silgi ucu (`TOOL_TYPE_ERASER`) gelirse o da doğrudan silgi olur.
- Tablette silgi modunu gösteren küçük bir gösterge ileride eklenebilir (Faz 5 kısayol çubuğu).
- **Güncelleme (2026-09-30, T-022/T-024 incelemesi):** 1 sn'lik süre host'ta son PEN mesajının **alındığı** andan sayılır. İstemci kendi kapısını son gönderdiği PEN mesajından sonra **1,2 sn** tutar; 200 ms'lik pay, ağ gecikmesi değişse de istemcinin gönderdiği basışın host'ta reddedilmemesi içindir (PROTOCOL §7). Çizim sırasında çift dokunmayla araç değişirse o vuruşun kalanı çizilmez (PROTOCOL §4).
