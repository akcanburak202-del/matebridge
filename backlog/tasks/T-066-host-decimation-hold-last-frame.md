---
id: T-066
title: Mac — seyreltmede ızgaradan erken gelen kare atılmaz, tutulur (son değişiklik her zaman gönderilir)
status: todo
phase: 5
owner: mac-host-dev
depends_on: [T-058]
decisions: []
files:
  - host-mac/Sources/MateBridgeCore/Video/FrameGate.swift
  - host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift
  - host-mac/Tests/
  - backlog/tasks/T-066-host-decimation-hold-last-frame.md
---

## Amaç

T-062 teşhisi. `FramePacer.offer` seyreltmede (`decimating`, panel 60 Hz iken 120 fps akış) ızgaradan önce gelen kareyi **atıyor** (`decimatedCount`, `.drop`). İçerik bir kez değişip duruyorsa (yazma: bir tuş genellikle 8,3 ms arayla iki kare üretir — karakter, sonra imleç/yeniden çizim) son kare hiç kodlanmıyor; tablet ara durumu gösterip bir sonraki değişikliğe kadar bekliyor. Şu an çalışan host (`bdf52f0`) seyreltme öncesi olduğu için kullanıcı bunu henüz görmedi; `main`'de var.

Değişmez: **yakalanan en yeni kare, sınırlı süre içinde kodlayıcıya verilir**; yalnızca daha yeni bir kare onun yerini alırsa atlanır.

## Kabul kriterleri

- [ ] Seyreltmede ızgaradan erken gelen kare `pending` olarak tutulur (en yeni kazanır). Izgara karesi gelirse onu değiştirir (bugünkü eşit aralıklı seçim korunur). Gelmezse bekleyen kare kendi slotunda + küçük bir pay (ör. kaynak aralığının yarısı; gerekçelendir) dolunca zamanlayıcıyla gönderilir. Sürekli 120→60 akışta gönderilen kareler hâlâ eşit aralıklı (zamanlayıcı yalnızca ardıl gelmediğinde devreye girer).
- [ ] Zamanlayıcıyla gönderilen kare, ızgarayı (gate) normal kabul gibi ilerletir; zaman damgaları geri gitmez (`lastSubmittedPtsUs`).
- [ ] `ev=cadence` satırında `decimated` artık yalnızca gerçekten atılan (değiştirilen) kareleri sayar; zamanlayıcıyla gönderilen ayrı sayılabilir (ör. `deferred=`), alan eklersen `docs/LOGGING.md`'yi değiştirme, karta yaz.
- [ ] Testler (`FrameGate`/`FramePacer` saf mantık): (1) 120 fps akış 60'a seyreltme: gönderilen aralıklar eşit, zamanlayıcı hiç tetiklenmez; (2) tek değişiklik: ızgaradan erken tek kare → slot + pay içinde gönderilir; (3) iki kare 8,3 ms arayla, sonra durgunluk → **ikinci kare gönderilir**; (4) 60→120 yükselişi hemen; (5) seyreltme kapalıyken davranış değişmez.
- [ ] `./scripts/check.sh` geçiyor.

## Kapsam dışı

- Tablet tarafı (T-065), SCK/kodlayıcı ayarları.

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
