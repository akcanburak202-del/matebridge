# 0026 — Deney ayarları (knob) politikası ve sınıflandırması

- **Durum:** kabul (2026-10-03)
- **Tarih:** 2026-10-03

## Bağlam
Kaynak: dış mimari incelemesi 2026-10-03 (HEAD a30c769), L02, D8 ve F3. Doğrulama:
- `docs/reviews/2026-10-03/verify-H-hygiene.md` (L02 envanteri, KNOB-0, ek 3–4);
- `coverage-audit.md` §4.1 K4.

Rapordaki "0019" taslağı bu numarayla yeniden numaralandı.

Ayar sayısı:
- İstemci 33 farklı açılış parametresi okuyor (`MainActivity.kt:295-498`, `WifiKnobs.kt:30-32`, `AudioPlayout.kt:94,114`, `NetBench.kt:39-59`; ef264dd).
- Host 25 `MATEBRIDGE_*` ortam değişkeni ve 4 CLI kipi okuyor (`main.swift:6-9`).

Bunların hiçbiri günlük ayar paneline ulaşmıyor. "Az sayıda doğrulanmış profil" zaten var (0013, 0014, 0016).

Asıl maliyet, sonuçlanmış deneylerin yaşam döngüsüne duyarlı kodda durması:
- GL sunum yolu iki ayrı yüzey yaşam döngüsü yaratıyor (H02/M03 riski).
- `nw` soketleri `SessionServer`'ın çift yığın kodunun büyük kısmını oluşturuyor.
- Boşta yenileme kodlayıcıya üçüncü bir çağıran ekliyor (M02).

Ek sorunlar:
- **Ayarlar başka uygulamalara açık.** `MainActivity` dışa açık (launcher) ve günlük APK debug varyantı (`scripts/install-apk.sh:15`). Bu yüzden ayarlara tabletteki her uygulama ulaşabilir. Yalnızca build türüne göre ayırmak yetmez.
- **Bir deney ayarı günlük duruma sızıyor.** `audio_buf_bursts` büyümesi kalıcı olarak kaydediliyor (T-110).

## Seçenekler
- **(a) Olduğu gibi kalsın.** Ayarlar dağınık kalır ve ölü dallar günlük yolda durur.
- **(b) Hepsi kaldırılsın.** Yeniden ayarlama ve tanı yeteneği kaybolur.
- **(c) Envanter, sınıflandırma ve geliştirici kapısı (önerilen).**

## Karar
Seçilen: **(c)**. Kullanıcı 2026-10-03'te onayladı, GL sunum yolunun ve `nw` soketlerinin kaldırılması dahil.

1. **Envanter.** Her ayar [`docs/KNOBS.md`](../KNOBS.md)'de listelenir: dosya:satır referansı, kartı, varsayılanı, sınıfı (kalır / yalnızca geliştirici / kaldırılır), sonucu ve uygulayan kart. Tablo H raporundaki L02 envanteridir; T-182 onu `main` `ef264dd` üzerinde koda karşı yeniden doğruladı (istemci 33 anahtar + 4 `net_bench` alt anahtarı, host 25 ortam değişkeni, 4 CLI kipi). Satır başına dosya referansları bu kararda tekrarlanmaz, `KNOBS.md` tek kaynaktır.
2. **Yeni ayar kuralı.** Yeni ayarların varsayılanı kapalıdır ve onları kapatacak kartı adlandırırlar. Deneyi sonuçlanan ayar, kapanış kartında ya da hemen ardından kaldırılır.
3. **Geliştirici kapısı.** İstemcide "yalnızca geliştirici" ayarları, aynı açılışta `--ez dev true` verilirse dikkate alınır.
4. **Profil satırı.** Her taraf oturum başında tek bir `ev=profile` satırı loglar. Satırda etkin mod, fps, ölçek, bit hızı, pacer ve varsayılan dışı ayarlar yer alır.
5. **Kaldırılacaklar:**
   - GL sunum yolu (T-018/T-019), `nw` soketleri (T-091/T-111), boşta yenileme (T-086/T-087);
   - perf hint, refresh vote, cpd pacer, inflight sınırı, oprate, keep_jitter/recenter, crypto bench;
   - `FRAME_DELAY`, `PRIO_SPEED`, `H264_PROFILE` ve `INPUT_RETAG=0`.

   T-019 ve T-067 "yapılmayacak" olarak kapanır.
6. **Kaldırılmayacaklar (audit K4).** İstemcinin Wi-Fi TOS, `wifi_ll` ve WifiLock ayarları, T-127 bunları `bsd` altında yeniden ölçene kadar geliştirici ayarı olarak kalır. 2026-10-01'deki "etkisiz" sonucu `nw` tavanı yüzünden geçersiz.

7. **Açık nokta: jitter tamponu 1–2 dalı.** `--ei jitter 1|2` (sabit tampon, `FramePacer`) T-052'den beri kayıtlı bir cihaz kazancı göstermedi; `jitter 0` Oyun modu üzerinden ulaşılabilir. Bu dal da kaldırılsın mı? Kullanıcının bu soruya ayrı bir cevabı kayıtlı değil. Bu yüzden dal **yalnızca geliştirici** kalır: T-183 `FramePacer`'ı silmez ve T-185 onu `dev` kapısının arkasına alır. Kullanıcı kaldırmayı seçerse küçük bir izleme kartı `FramePacer`'ı siler, günlük yoldaki `VsyncClock`'u (`FramePacer.kt:18`) korur.

**Onaylandı (2026-10-03).** Sorulan (manifest §5 soru 5): GL sunum yolunun ve Network.framework (`nw`) soketlerinin kaldırılmasını onaylıyor musun? İkisi de gayriresmî olarak "seçenek olarak dursun" denmişti.

Kullanıcının cevapları (2026-10-03):
- **GL sunum yolu** (`--es render gl`, `frate`, `glpts`, `GlPresenter`): kaldırılır, onaylandı → T-184.
- **`nw` soketleri** (`MATEBRIDGE_VIDEO_SOCKET=nw`, `MATEBRIDGE_CONTROL_SOCKET=nw`): kaldırılır, onaylandı → T-186.
- **Jitter tamponu 1–2:** ayrı cevap yok; madde 7'ye göre yalnızca geliştirici kalır.

## Sonuçlar
- **Kazanılan:**
  - Günlük video ve oturum yolunda daha az dal.
  - Tek yüzey yaşam döngüsü.
  - Daha küçük `SessionServer` ve kodlayıcı yüzeyi.
  - Her logda etkin profil görünür. Ayarlara başka uygulamalar kazara ulaşamaz.
- **Kaybedilen:** kaldırılan deneyleri yeniden denemek için git geçmişinden geri getirmek gerekir.
- **Kapıladığı kartlar:**
  - T-182: envanter ve karar kaydı.
  - T-183: istemci deneyleri.
  - T-184: GL yolu.
  - T-185: geliştirici kapısı ve `ev=profile`.
  - T-186: host `nw` soketleri.
  - T-204: host kodlayıcı deneyleri ve `ev=profile`.
- **Mevcut kararlar:** değişmez. 0013, 0014 ve 0016 profilleri aynı kalır.
- **PROTOCOL.md:** değişmez. LOGGING.md'ye `ev=profile` satırı eklenir.
- **Tekrar düşünülür:** bir işletim sistemi güncellemesi kaldırılan bir yolu yeniden gerekli kılarsa. Örnek: HarmonyOS GL yüzeyini 120 Hz'e açarsa ya da bir PerformanceHint oturumu verirse.
