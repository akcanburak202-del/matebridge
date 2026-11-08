# 0044 — USB'de 120 Hz'i tut: host adb ile periyodik sahte dokunma (deneysel, varsayılan kapalı)

- **Durum:** kabul (kullanıcı onayı 2026-11-08: "evet, 1'i dene")
- **Tarih:** 2026-11-08

## Bağlam

Huawei AGP paneli yalnız dokunma, kalem, fare ya da trackpad görünce 120 Hz'e çıkarıyor. Kumandayla ya da klavyeyle oynanan Oyun 120'de panel 60'a iniyor; host `DISPLAY_RATE` yüzünden akışı 60'a düşürüyor (0016). Her 60↔120 geçişi takılma olarak görünüyor (kullanıcı 2026-11-08).

2026-11-08 AGP araştırması (NOTES) uygulama içinden ve adb'den bütün temiz yolları kapattı:
- AGP'nin sahne, dokunma ve zorla yenileme komutları yalnız uid 1000'e açık.
- Animasyon oyu bu cihazda desteklenmiyor ("not support LTPO2.0").
- `aps_service` sahne adına sonek ekliyor, bu yüzden "TARGET_FPS_120HZ" sahnesi hiç eşleşmiyor.
- shell'in AGP'ye bağlanmasını SELinux engelliyor.

Çalışan tek yol shell'den enjekte edilen dokunma: 2026-10-20'de bir dokunma paneli 1,5–2,5 sn 120'de tuttu (0041 eki). 0041'de bu yol "kablosuz adb kalıcı değil" diye bırakılmıştı. USB'de adb her zaman var: host tünelleri zaten adb ile kuruyor (`UsbTunnelWatcher`). Tablette `input` bir JVM başlatmıyor, `cmd input` ile system_server'a gidiyor (~30 ms duvar süresi), yani saniyede bir çağrının maliyeti düşük.

## Karar

1. **Host** `MATEBRIDGE_HOLD120=1` açıkken, aşağıdaki koşulların hepsi sağlandıkça yaklaşık **1 sn'de bir** `adb -s <seri> shell input touchscreen tap 2 2` gönderir:
   - USB oturumu var ve adb seri numarası biliniyor;
   - video akıyor;
   - Oyun ekranı etkin ve akış 120 fps.

   Yalnız `tap` kullanılır (bas+bırak tek komutta). Ayrı `motionevent DOWN` asla gönderilmez, böylece tablette basılı kalan bir dokunma oluşmaz.
2. Tabletten son **1,5 sn** içinde dokunma, kalem ya da işaretçi girdisi geldiyse host dokunma göndermez. Gerçek girdi paneli zaten 120'de tutar. Bu bekleme, sahte dokunmanın gerçek bir dokunuşla aynı anda gelme olasılığını da azaltır: Android ikinci aygıtın dokunuşunu atar.
3. **İstemci** bu dokunmayı yutar ve Mac'e asla göndermez. Ölçüt: aygıtı gerçek bir giriş aygıtı değil (sanal ya da bilinmeyen `deviceId`), tek parmak, sol üst köşede (≤ 4 px). Yutulan dokunma boşta sayacını (T-234) ve diğer "kullanıcı etkin" sinyallerini beslemez. Başka konumdaki adb dokunmaları (test araçları) eskisi gibi Mac'e gider.
4. Protokol değişmez. Açma/kapama şimdilik yalnız host ortam değişkeni (geliştirici anahtarı, KNOBS). Kullanıcı beğenirse panel anahtarı ayrı bir kararla eklenir.
5. Wi-Fi'de hiç çalışmaz. Kablosuz adb kalıcı değil, bu karar onu kapsamıyor.

## Sonuçlar

- Kumandayla Oyun 120 gerçekten 120 Hz kalır, 60↔120 geçiş takılmaları biter. Bedeli: panel ve çözücü sürekli 120'de çalışır, ısı ve pil biraz artar (USB'de tablet şarj oluyor). Ölçülecek.
- Risk: sahte dokunmanın sürdüğü birkaç milisaniyeye denk gelen gerçek bir dokunuş (kalem dahil) Android tarafından atılabilir. 2. madde bunu azaltır; cihaz testinde ölçülür.
- Risk: istemcinin yutma ölçütü yanlışsa dokunma Mac'e tıklama olarak gider. Cihazda önce yalnız istemci kurulur ve elle `input tap 2 2` ile doğrulanır.
- Huawei'ye özgü davranışa dayanır; HarmonyOS güncellemesinde etkisiz kalabilir.
- Yeniden düşünme: yutma güvenilmezse, gerçek dokunuş kaybı görülürse ya da ısı/pil bedeli kabul edilemezse kaldırılır.
