# Backlog

Her iş bir **görev kartıdır**: `tasks/T-XXX-kisa-ad.md`. Kart, ajanla orkestratör arasındaki sözleşmedir. Ajan karttaki kapsamın dışına çıkmaz.

Format, [Backlog.md](https://github.com/MrLesk/Backlog.md)'nin yaklaşımına benzer: düz Markdown, YAML frontmatter, kabul kriterleri, uygulama planı ve handoff. Ek bir araç gerekmez.

## Durumlar

`todo` → `in-progress` → `review` → `done`. Takılan iş `blocked` olur. Takılma nedeni kartın *Açık sorular* bölümüne yazılır.

## Akış

1. Orkestratör kartı yazar: amaç, kapsam, `files:`, kabul kriterleri.
2. Ajan kartı alır ve `status: in-progress` yapar. *Plan* bölümü boşsa önce planı yazar.
3. Ajan uygular, `./scripts/check.sh` çalıştırır ve geçer.
4. Ajan *Handoff* bölümünü doldurur ve `status: review` yapar.
5. Orkestratör inceler. Kritik değişikliklerde Codex de inceler.
6. Cihaz testi gerekiyorsa orkestratör yapar, gerekirse kullanıcıya test listesi verir.
7. Birleştirme sonrası kart `done` olur, `./scripts/board.sh` ile `BOARD.md` yenilenir.

## Kurallar

- Bir kart tek bağlam penceresine sığacak büyüklükte olmalıdır. Büyükse bölünür.
- Aynı dosyaya dokunan iki kart aynı anda `in-progress` olamaz.
- `BOARD.md` elle düzenlenmez. Kartların frontmatter'ından üretilir.
