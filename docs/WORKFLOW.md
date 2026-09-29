# MateBridge — Çalışma Düzeni

**Tarih:** 2026-09-29

## Roller

| Rol | Kim | Sorumluluk |
|---|---|---|
| Ürün sahibi + test | Kullanıcı | Kararlar, gerçek cihazda deneme ("elde nasıl hissettiriyor"), aşama onayı |
| Orkestratör | Claude Opus 5.5 | Görev bölme, mimari/protokol, kritik kod (kalem enjeksiyonu, koordinat dönüşümü, girdi durumu), birleştirme, son inceleme, raporlama |
| Uygulayıcı | Claude Sonnet 5.5 alt ajanları | Net tanımlı görevler: iskelet, arayüz, tablolar, test uygulamaları. Gerekirse ayrı git worktree'lerde paralel çalışır. |
| İç denetçi | Claude Sonnet 5.5 `reviewer` alt ajanı | Her görevin diff'ini kart ve AGENTS.md kurallarına göre salt okunur inceler |
| Bağımsız denetçi | Codex (`gpt-6-sol`, varsayılan efor) | Kritik değişiklikleri **salt okunur** inceler (`scripts/codex-review.sh`). Dosya değiştirmez. |

Alt ajan tanımları `.claude/agents/` altında: `mac-host-dev`, `android-client-dev`, `reviewer`. İş akışı `backlog/README.md`'de.

### Codex kullanımı

- Varsayılan: `codex exec review` veya `codex exec -s read-only -m gpt-6-sol "<inceleme isteği>"`
- Efor: varsayılan (medium). Yalnızca çok kritik incelemelerde (protokol, girdi durumu, güvenlik) `-c model_reasoning_effort="high"` kullanılır.
- `gpt-6-astra` pahalı, **kullanıcı onayı olmadan kullanılmaz.**

## Kurallar

1. Her görevin bir görev kartı olur: amaç, dokunulabilecek dosyalar, "bitti" ölçütü, nasıl test edileceği.
2. Bir modülü aynı anda yalnızca bir ajan değiştirir.
3. Birleştirme koşulları: derleme geçer, orkestratör inceler, kritik parçalarda Codex de inceler.
4. Her adımın sonunda kullanıcıya 3–5 maddelik "tablette şunu dene" listesi verilir.
5. Ajan sayısı sabit bir sınırla değil, **bağımsız iş akışı sayısıyla** belirlenir (bkz. "Paralellik" bölümü).
6. `main` dalı her zaman derlenebilir durumda kalır. Commit'ler küçük ve anlamlıdır.
7. Tablet USB ile bağlıyken APK kurulumu, logcat ve ekran görüntüsü (`adb exec-out screencap`) ile doğrulama orkestratör tarafından yapılabilir.

## Paralellik

Yerel kaynak (32 GB RAM) darboğaz değil: modeller bulutta çalışır, yerelde sadece derleme ve araç süreçleri çalışır. Gerçek sınırlar şunlar:

- **Bağımlılıklar:** Protokol donmadan host ve client aynı mesajlar üzerinde paralel yazılamaz.
- **Tek cihaz:** Tek tablet ve tek Mac var. Cihaz testleri (APK kurma, sanal ekran, izinler) sırayla yapılır.
- **İnceleme kapasitesi:** Her yazan ajanın çıktısını orkestratör inceler. Ajan sayısı artınca inceleme sığlaşır.

Bu yüzden:

| Ajan türü | Sınır |
|---|---|
| **Yazan ajan** (dosya değiştirir) | Sahipliği ayrı, arayüzü donmuş her modül için 1 ajan. Her biri kendi git worktree'sinde. Pratikte 2–4. |
| **Okuyan ajan** (araştırma, inceleme, Codex review) | Çakışma üretmez. İşe göre 5–8'e kadar paralel çalışabilir. |
| **Cihaz testi** | Her zaman tek seferde bir tane. |

Paralel yazmaya başlamadan önce ortak arayüz (`docs/PROTOCOL.md`, mesaj tanımları) donmuş olmalıdır.

## Repo

- GitHub, **public**. Lisans: Apache-2.0 (android-display ile uyumlu).
- Commit'lerde GitHub **noreply** e-posta adresi kullanılır.
- Repoya log, cihaz seri numarası veya kişisel veri commit'lenmez.
