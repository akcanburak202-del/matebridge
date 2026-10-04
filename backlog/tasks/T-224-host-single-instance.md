---
id: T-224
title: Host — only one MateBridge instance may run (second instance exits)
status: todo
phase: 6
owner: mac-host-dev
depends_on: [T-148]
decisions: []
files:
  - host-mac/Resources/Info.plist
  - host-mac/Sources/MateBridgeApp/main.swift
  - host-mac/Sources/MateBridgeApp/LoginItem.swift
  - host-mac/Sources/MateBridgeCore/Session/SingleInstancePolicy.swift
  - host-mac/Tests/MateBridgeCoreTests/Session/
  - docs/LOGGING.md
  - backlog/tasks/T-224-host-single-instance.md
---

## Amaç

Cihaz 2026-10-04 ~12:15: Mac menü çubuğunda iki MateBridge simgesi. İki süreç (`build/MateBridge.app`), ikisi de 10:49:25'te başlamış (orkestratörün `quit` + `open --env MATEBRIDGE_LAT_TRACE=1` yeniden başlatmasıyla aynı an). Biri 47001/47002'yi, ikincisi port düşüşüyle rastgele 61082/61083'ü dinliyordu — Bonjour'da ikinci bir hizmet olarak görünebilir ve Wi-Fi'de tablet yanlış kopyaya bağlanabilir; iki USB izleyicisi, iki menü. İkinci süreç elle öldürüldü.

## Bağlam

- Olası nedenler (ajan doğrular): (a) `open` ile açılan kopya + açılışta `SMAppService.mainApp.register()` (T-148 her açılışta kayıt yeniden denemesi) launchd'ye uygulamayı bir kez daha başlattırıyor olabilir; (b) Info.plist'te `LSMultipleInstancesProhibited` yok, `open --env` ve login item birlikte iki kopya açabilir.
- İstenen: tek kopya garantisi. Info.plist `LSMultipleInstancesProhibited = true` ve açılışta, aynı bundle id'li başka bir çalışan süreç varsa (`NSRunningApplication.runningApplications(withBundleIdentifier:)`, kendisi hariç) yeni kopya **dinleyici açmadan, ekran kurmadan** loglayıp çıkar (`ev=second_instance action=exit`). Karar saf bir Core fonksiyonunda (test edilir).
- Ayrıca T-148'in kayıt yolunun yeni bir kopya başlatıp başlatmadığı doğrulanır; başlatıyorsa kayıt ancak gerektiğinde yapılır.

## Kabul kriterleri

- [ ] [XCTest] `SingleInstancePolicy`: başka kopya varken → çık; yalnızken → devam; kendi pid'i sayılmaz.
- [ ] [device] `quit` + `open` ve login-item kayıt yolu sonrasında `pgrep -x MateBridgeApp` tek süreç; menü çubuğunda tek simge; 47001/47002 dinleniyor.
- [ ] [device] Elle ikinci `open -n build/MateBridge.app` → ikinci kopya `second_instance action=exit` loglayıp çıkar, mevcut oturum etkilenmez.

## Plan

_(Ajan kodlamadan önce doldurur.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulananlar:**
- **Açık sorular:**
