# 0031 — Boşta karartma ve kapatma (tablet)

- **Durum:** kabul
- **Tarih:** 2026-10-05

## Bağlam

Monitör araştırması (docs/research/2026-10-04-monitor-vs-matebridge.md §4.1, öneri A): istemci `FLAG_KEEP_SCREEN_ON`'u hep tutuyor (`MainActivity.kt:383`), host oturum boyunca `PreventUserIdleDisplaySleep` tutuyor. Kullanıcı masadan kalkınca hiçbir şey ekranı karartmıyor (OLED yanma, pil, enerji). T-128 gerekçesi "boşta kalmayı tabletin kendi zaman aşımı yönetir" diyordu ama bayrak bunu engelliyor. PLAN Aşama 4 "ekran uyumaz" maddesi oturum açılırken uyumamayı kastediyordu, kalıcı boşta açık kalmayı değil. Kullanıcı seçimleri 2026-10-05.

## Karar

- **Boşta sayacı:** tablette yerel girdi (dokunma, kalem temas ya da hover, klavye, trackpad/fare, kaydırma) olmadığı her an sayılır. Basılı bir şey varken (parmak camda, kalem temasta, tuş ya da düğme basılı) sayaç durur. Mac'e doğrudan bağlı aygıtların girdisi görünmez (protokol değişmez; gerekirse sonra).
- **Süre:** yan panelde seçilebilir: 2 / 5 / 10 / 15 dk / Kapalı. Varsayılan **5 dk**. Kalıcı (prefs).
- **Oyun modunda sayaç çalışmaz.** Oyunlar çoğu zaman Mac'e bağlı bir kumanda ile oynanır ve tablette girdi olmaz. Çizim ve Günlük modlarda çalışır.
- **1. aşama, kısma:** süre dolunca pencere parlaklığı düşürülür (`WindowManager.LayoutParams.screenBrightness`, görünür ama çok koyu). Oturum, video ve ses sürer.
- **2. aşama, kapatma:** kısmadan sonra 1 dk daha girdi yoksa `FLAG_KEEP_SCREEN_ON` kaldırılır. Tabletin kendi ekran zaman aşımı devreye girer (sayaç son kullanıcı etkinliğinden işlediği için genelde hemen). Ekran kapanınca mevcut zincir çalışır: onStop → release-all + BYE; Mac kendi ayarına göre uyur; tablet açılınca Mac'i uyandırır (T-128..T-134).
- **İlk dokunuş yalnız uyandırır:** kısılmışken gelen ilk girdi Mac'e gitmez. Bütün hareket yutulur: dokunmada tüm parmaklar kalkana kadar, kalemde kalem kalkana kadar, tuşta o tuşun up'ına kadar. Bırakma olayı yutulan bir basışa aitse o da yutulur; daha önce Mac'e gönderilmiş bir basışın bırakması asla yutulmaz (release-all kuralı). Parlaklık ve bayrak eski haline döner, sayaç sıfırlanır.
- Parlaklık, mevcut sistem/otomatik parlaklığa dokunmadan yalnız pencere düzeyinde değişir. Uygulama arka plana geçerse pencere ayarı zaten düşer.

## Sonuçlar

- OLED yanma ve pil riski azalır; Mac de boşta uyuyabilir (T-128'in varsayımı gerçek olur).
- Kaybedilen: Günlük/Çizim modunda tablete dokunmadan uzun video izlerken ekran kararır. Çözüm Kapalı seçmek ya da süreyi uzatmak.
- Tekrar düşünülür: Mac'e bağlı klavye/fare ile çalışırken kararma rahatsız ederse (host'tan "Mac'te kullanıcı etkin" sinyali, protokol değişikliği), ya da tablette ekran zaman aşımı çok uzunsa (aktif kapatma için başka yol).
- PLAN Aşama 4 "ekran uyumaz" maddesi bu kararla daralır: oturum açılırken ve kullanılırken uyumaz.
