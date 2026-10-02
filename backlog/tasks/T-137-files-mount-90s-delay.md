---
id: T-137
title: Dosyalar — Finder'da bağlama her seferinde tam 90 s sürüyor (kök neden + düzeltme)
status: todo
phase: 5
owner: android-client-dev
depends_on: [T-135, T-136]
decisions: [0015]
files:
  - client-android/app/src/
  - host-mac/Sources/MateBridgeHost/Files/
  - host-mac/Sources/MateBridgeCore/Files/
  - host-mac/Tests/
  - tools/dav-repro/
  - backlog/tasks/T-137-files-mount-90s-delay.md
---

## Amaç

Cihaz (2026-10-02 ~17:25 ve ~17:33): "Tablet dosyalarını aç" → `ev=mount result=ok ms=90187` ve ikinci kez `ms=90120` (izin penceresi ikinci seferde yok). Tablette: tek istek (`reqs=1 bytes_in=131 bytes_out=918`), sonra **90 s hiç istek yok**, sonra normal trafik (`reqs=7`, `reqs=92`) ve birim açılıyor. Sunucu her yönteme (OPTIONS dahil) `401 Digest` veriyor. NetFS çağrısı: `NetFSMountURLAsync(http://127.0.0.1:<port>/MatePad/, user "matebridge", password=jeton, openOptions UI yok + AllowLoopback, SoftMount)`.

Hipotezler (doğrula, tahminle düzeltme yapma): (a) webdavfs/NetAuth ilk 401'de kimlik bilgisi için UI/agent bekliyor, 90 s zaman aşımından sonra verilen kimlik bilgisini kullanıyor; (b) sunucunun bir yanıtı (ör. OPTIONS/ilk istek) gövde uzunluğu / keep-alive yüzünden istemciyi okuma zaman aşımına kadar bekletiyor; (c) Digest/Basic seçimi.

## Kabul kriterleri

- [ ] **Mac'te tekrar üretim:** `DavServer` JVM'de (Android'siz, test sınıflarıyla) Mac'te bilinen bir jetonla çalıştırılır (`tools/dav-repro/` altında betik; Android Studio JDK: `/Applications/Android Studio.app/Contents/jbr/Contents/Home`), ve aynı NetFS seçenekleriyle (küçük Swift betiği ya da `mount_webdav`) bağlanır; süre ve istek/yanıt dökümü (yöntem, durum kodu, başlıklar, zamanlar — jeton hariç) alınır. 90 s gecikme yeniden üretilir.
- [ ] Kök neden bulunur ve düzeltilir (sunucu ve/veya host tarafı). Hedef: bağlama < 3 s. Güvenlik modeli değişmez (her istek kimlik doğrulamalı; jeton loglanmaz; yalnız 127.0.0.1).
- [ ] Düzeltmeden sonra tekrar üretim betiğiyle bağlama süresi ölçülür ve Handoff'a yazılır. Mevcut testler + yeni regresyon testi; `./scripts/check.sh` geçiyor.
- [ ] Mac'te gerçek `/Volumes` bağlaması yapılırsa test sonunda ayrılır; çalışan MateBridge host'una ve onun `/Volumes/MatePad` birimine dokunulmaz (başka port ve birim adı kullan).

## Plan

(ajan doldurur)

## Handoff

(ajan doldurur)
