# 🎯 vbs_core_matrix

**Katman 1-8 Birleşik Motor** — FiveM Qbox resource

Adli balistik • Kartel hiyerarşisi • Karaborsa • Trap House • Mutfak • POLIS AI • Taktik HUD • Drive-By AI

---

## 📋 İçindekiler

1. [Sistem Gereksinimleri](#️-sistem-gereksinimleri)
2. [Zorunlu Bağımlılıklar](#-zorunlu-bağımlılıklar)
3. [Opsiyonel Bağımlılıklar](#-opsiyonel-bağımlılıklar)
4. [Kurulum Adımları](#-kurulum-adımları)
5. [xsound Kurulumu](#-xsound-kurulumu)
6. [ox_inventory Item Tanımları](#-ox_inventory-item-tanımları)
7. [Script Çakışma ve Temizlik](#-script-çakışma-ve-temizlik)
8. [Önemli Komutlar](#-önemli-komutlar)
9. [Bilinen Konular](#-bilinen-konular)
10. [Son Sürüm Notları](#-son-sürüm-notları)

---

## 🖥️ Sistem Gereksinimleri

| Bileşen | Minimum | Önerilen |
|---------|---------|----------|
| FXServer | 6683+ | 7290+ |
| MariaDB | 10.6+ | 11.x |
| Lua | 5.4 | 5.4 |
| oxmysql | 2.7+ | 2.8+ |
| ox_lib | 3.30+ | son sürüm |

---

## 📦 Zorunlu Bağımlılıklar

Bu resource **ÇALIŞMAZ** bunlar olmadan. Hepsini `server.cfg`'de `ensure` sırasıyla yükle (bkz. `fxmanifest.lua`'daki `dependencies` bloğu — buradaki liste onunla birebir eşleşir):

```cfg
# === Core Framework ===
ensure oxmysql
ensure ox_lib
ensure qbx_core

# === Envanter ===
ensure ox_inventory

# === Hedefleme (Target) ===
ensure ox_target

# === İç Mekan (Trap House interior render'ı) ===
ensure bob74_ipl

# === Ses (composer_intro.lua ambiyans müziği + telsiz parazit) ===
ensure xsound
ensure pma-voice
# (pma-voice yerine mumble-voip kullanıyorsanız SetRadioStatic export'unu
#  karşılayan bir ses kaynağı gerekir -- bkz. server/main.lua satır 119)

# === vbs_core_matrix ===
ensure vbs_core_matrix
```

> **Not:** `ox_target` `fxmanifest.lua`'nın `dependencies` listesinde bildirilmiş ancak kod tabanında doğrudan bir `exports['ox_target']` çağrısına rastlanmadı — muhtemelen ilerideki bir etkileşim noktası için ayrılmış. Eksik olsa da resource şu an çökmez.

---

## 🧩 Opsiyonel Bağımlılıklar

Aşağıdakiler olmadan da resource açılır; yalnızca ilgili özellik sessizce devre dışı kalır (hepsi `pcall` ile sarılı):

- **screencapture** — loglarda görülen ayrı bir resource, vbs_core_matrix'in parçası değil.
- **qbx_core dışı framework'ler** desteklenmiyor (kod tabanı `Matrix.QBX`/`Matrix.GetOrCreatePlayerState` üzerinden qbx_core'a doğrudan bağımlı).

---

## 🚀 Kurulum Adımları

1. Bu klasörü `resources/` altına `vbs_core_matrix` adıyla kopyalayın.
2. `sql/matrix_v3_ultimate_combined.sql` dosyasını veritabanınıza tek seferde çalıştırın (5 fazın tamamını, doğru bağımlılık sırasıyla, idempotent olarak içerir — ayrı ayrı `matrix_financial_core.sql` / `matrix_bot_cognition.sql` / `phase3_persistent_vehicles.sql` / `phase4_hardcore_friction.sql` / `phase5_coercion_matrix.sql` çalıştırmanıza gerek yoktur).
3. Aşağıdaki [ox_inventory Item Tanımları](#-ox_inventory-item-tanımları) bölümündeki item'ları `ox_inventory/data/items.lua`'ya ekleyin.
4. `server.cfg`'ye [Zorunlu Bağımlılıklar](#-zorunlu-bağımlılıklar) bölümündeki `ensure` satırlarını (doğru sırayla) ekleyin.
5. Sunucuyu başlatın ve konsolu izleyin: `Config.Diagnostics.RunOnResourceStart = true` ise açılışta otomatik derin tanı çalışır ve `[MATRIX:DIAGNOSTICS] N/155 basarili ...` satırını basar. `N` 155'ten düşükse bkz. [Önemli Komutlar](#-önemli-komutlar) → Tanı (Diagnostics).

---

## 🔊 xsound Kurulumu

`client/composer_intro.lua`, resource başlarken (ve trap house olaylarında) ambiyans müziği çalmak için `xsound` export'larını kullanır:

- `exports.xsound:PlayUrl(soundId, url, volume, false)`
- `exports.xsound:Destroy(soundId)`

Her çağrı `pcall` ile sarılıdır — xsound kurulu değilse, çalışmıyorsa veya ses dosyası 404 dönerse **hiçbir hata fırlatılmaz, ses sessizce çalınmaz**. Yani xsound olmadan resource açılır, sadece ambiyans müziği duyulmaz.

Kurulum: [xsound](https://github.com/xConnDev/xSound) resource'unu edinip `ensure xsound` ile yükleyin; ek bir config gerekmez, script kendi ses URL'lerini kod içinden sağlar.

---

## 🎒 ox_inventory Item Tanımları

Aşağıdaki item'lar kod tabanında (`shared/config.lua`, `server/*.lua`) adı geçen, gerçekten kullanılan item'lardır. Ağırlık/stack/consumable gibi ayarlar sunucu ekonominize göre sizin belirlemenize bırakılmıştır — burada yalnızca **isim, amaç ve nerede kullanıldığı** listelenmiştir.

### Silahlar & Mühimmat

| Item | Kullanım | Kaynak |
|---|---|---|
| `weapon_combatpistol` | Namlu değişimi whitelist'inde (seri no silinebilir) | `shared/config.lua` |
| `weapon_assaultrifle` | Namlu değişimi whitelist'inde | `shared/config.lua` |
| `weapon_spare_barrel` | `/namludegistir` tarafından tüketilen sarf malzemesi | `server/forensics.lua` |
| `ammo_pistol` | Karaborsa mühimmat kataloğu (x60, elden teslim) | `shared/config.lua` |
| `ammo_rifle` | Karaborsa mühimmat kataloğu (x90, elden teslim) | `shared/config.lua` |

### Karaborsa (Blackmarket) sarf malzemeleri

| Item | Kullanım |
|---|---|
| `burner_phone` | Açık hat / sahte IMEI telefon — COMINT ve canlı yayın (livestream) mekaniklerinin ön koşulu |
| `yiv_set_raybasi` | Namlu değişimi için gerekli 3 malzemeden biri (`RequiredItems`) |
| `namlu_celik_tiraslama` | Namlu değişimi için gerekli malzeme |
| `mekanik_igne_yayi` | Namlu değişimi için gerekli malzeme |

### Mutfak / Üretim (Kitchen)

| Item | Kullanım |
|---|---|
| `meth_raw_batch` | Ham metamfetamin partisi (`Matrix.Kitchen.ProcessCook` çıktısı) |
| `cutting_agent` | Paketleme odasında saflığı seyreltmek için kesme ajanı |
| `meth_bag` | Nihai kurye paketi (10g, metadata.purity taşır) — aynı zamanda Hidrolik Pres'in `meth_bag` ürün tipi için bag girdisi |
| `coke_brick` | Kokain kalıbı — Kitchen'ın nihai kurye paketi (Hidrolik Pres'teki `coke_bag`'den FARKLI bir item) |

### Endüstriyel Botanik (Kitchen — Faz 6)

| Item | Kullanım |
|---|---|
| `weed_raw` | Botanik kabininden hasat edilen ham ürün |
| `masterpiece_gourmet_weed` | Yüksek katsayılı (≥ belirli eşik) usta işi çıktı |
| `trash_weed` | Düşük katsayı/durağanlık durumunda üretilen, satılamayan çöp ürün (x10 adet) |

### Hidrolik Pres (Logistics — Faz 6)

| Item | Kullanım |
|---|---|
| `heavy_duty_press_bag` | Pres başına gereken ağır hizmet tipi torba (100 bag : 1 tuğla oranı) |
| `narcotic_brick` | Presin çıktısı — 1000g ağırlığında, ağırlıklı ortalama saflık metadata'sı taşır |
| `coke_bag` | `coke_brick` ürün tipi için pres girdisi (stashBagItem) |
| `masterpiece_gourmet_weed` | Aynı zamanda kendi ürün tipi için pres girdisi olarak da kullanılır |

### Adli (Forensics)

| Item | Kullanım |
|---|---|
| `shell_casing_evidence` | `/kovantopla` ile toplanan kovan — balistik ID metadata'sı taşır, DB'deki adli kaydı fiziksel olarak temsil eder |

### Tezgah (Workbench) tamir sarf malzemeleri

| Item | Kullanım |
|---|---|
| `steel_wire_brush` | Silah tamiri gereksinimi |
| `abrasive_sandpaper` | Silah tamiri gereksinimi |
| `industrial_acid_solvent` | Silah tamiri gereksinimi |

### Prop modelleri (envanter item'ı DEĞİL — dünya objesi)

| Model | Kullanım |
|---|---|
| `prop_gun_barrel_01` | Workbench'te namlu materialize/dematerialize (`CreateObject`) |
| `prop_clean_agent` | Adli asit temizliği sırasında oyuncuya iliştirilen prop |

### Sadece test/tanı amaçlı (opsiyonel)

| Item | Kullanım |
|---|---|
| `matrix_diagnostic_token` | Yalnızca `deep` tanının eşzamanlılık stres testinde kullanılır (`Config.Diagnostics.StressTestItem`). ox_inventory'de kayıtlı DEĞİLSE test **atlanır** — resource'un çalışması için ZORUNLU değildir. |

---

## 🧹 Script Çakışma ve Temizlik

- **Trevor'ın treyleri**: Trap House iç mekan render'ı için varsayılan GTA treyleri tamamen terk edildi; yerine `bob74_ipl`'in `GetGTAOHouseLow1Object()` export'u kullanılıyor (`client/trap_house_client.lua`). `bob74_ipl` kurulu değilse veya export başarısız olursa iç mekan doğru render OLMAYABİLİR — teşhis için `/traphouseipldebug` komutunu çalıştırın.
- **matrix_pending_refunds şema çakışması**: `sql/matrix_financial_core.sql` ve `sql/phase3_persistent_vehicles.sql` aynı tabloyu farklı şemalarla `CREATE TABLE IF NOT EXISTS` ile tanımlar. `sql/matrix_v3_ultimate_combined.sql`'i kullanıyorsanız (önerilen) financial_core önce çalıştığı için onun daha kapsamlı şeması kazanır — bu kasıtlı ve zararsızdır.
- Bu resource `Matrix` global tablosunu paylaşır; aynı isimde başka bir global tanımlayan resource'larla çakışabilir.

---

## ⌨️ Önemli Komutlar

Kod tabanında toplam **151 `RegisterCommand`** bulunuyor (141 server + 10 client) — çoğu geliştirici/test amaçlı. Aşağıda günlük yönetim ve tanı için gerçekten önemli olanlar kategorilere ayrılmıştır. Tam liste için ilgili dosyalarda `RegisterCommand(` arayın.

### 🩺 Tanı (Diagnostics) — EN ÖNEMLİLERİ
| Komut | Açıklama |
|---|---|
| `/matrix_run_diagnostics` | Hızlı tanı çalıştırır (155 kontrolün "fast" katmanı) |
| `/matrix_run_diagnostics deep` | Derin tanı: config sabotaj testi + simülasyon kontrolleri + kullan-at test botu dahil TÜM 155 kontrol |
| `/matrix_diag_detay failed` | Son rapordaki **başarısız** kontrolleri döker (yeniden çalıştırmadan) |
| `/matrix_diag_detay deep` | Yeni bir deep tanı çalıştırıp TÜM sonuçları döker |
| `/matrix_diag_detay verbose` | Tüm 155 kontrolü detaylarıyla döker |
| `/matrix_diag_detay g <metin>` | İsminde `<metin>` geçen kontrolleri filtreler |
| `/matrix_diag_detay layer <N>` | Belirli bir "KATMAN N" grubunu filtreler |
| `/matrix_diag_detay journal` | Boot sırasında yakalanan hata jurnalini gösterir |
| `/matrix_debug_map` | (client) HUD üzerinde debug harita katmanını açar/kapatır |

### 🏚️ Trap House / Büro Yönetimi
| Komut | Açıklama |
|---|---|
| `/traphouseekle [label] [x] [y] [z]` | Yeni trap house oluşturur |
| `/traphousedurum [id]` | Deşifre/heat/düzenlilik/baskın durumunu gösterir |
| `/baskinzorla [id]` | Baskını test amaçlı zorla tetikler |
| `/baskinsonuclandir [id] [captured\|escaped\|eliminated]` | Baskın sonucunu kaydeder |
| `/burokilitdurum [id]` / `/burokilitzorla [id]` | Büro kilidi (lockdown) durumu / zorlama |
| `/opsecparola [id] [parola]` | Trap house dinamik parolasını değiştirir |
| `/traphouseipldebug` | (client) bob74_ipl interior render teşhisi |

### 🤖 Bot / Ajan Yönetimi
| Komut | Açıklama |
|---|---|
| `/botyarat`, `/botspawn`, `/botdespawn` | Bot oluşturma/sahaya sürme/geri çekme |
| `/botdurum [id]` | Bir botun tam durumunu gösterir |
| `/botkilitac [id]` | Bot kilidini açar |
| `/operatiftasfiye [id]` | Botu operasyondan kalıcı olarak tasfiye eder |
| `/cetelideriata [citizenid]` | Hiyerarşi liderliği atar |
| `/matrixdump` | Tüm `Matrix.Bots` tablosunu döker (ağır — yalnızca debug) |

### 🍳 Mutfak / Üretim / Lojistik
| Komut | Açıklama |
|---|---|
| `/paketleuret` | Paketleme odası testi |
| `/botanikbaslat`, `/botanikdurum` | Endüstriyel botanik (Faz 6) başlatma/durum |
| `/presle`, `/presdurum`, `/presiptal` | Hidrolik pres işlemleri |
| `/sevket`, `/dropiste`, `/dropcek`, `/dropdurum` | Sevkiyat / dead-drop akışı |
| `/filokaydet`, `/filoata`, `/filobirak` | Araç filosu yönetimi |
| `/araciyak` | Kundaklama (arson) akışını test tetikler |

### 💰 Piyasa / Ekonomi
| Komut | Açıklama |
|---|---|
| `/nakityatir`, `/nakitakla`, `/nakitdurum` | Kirli nakit / aklama akışı |
| `/piyasasorgu`, `/piyasasifirla` | Bölgesel piyasa durumu / sıfırlama |
| `/escrowdurum` | Banka escrow (24s kilit) durumu |
| `/denetleyiciata`, `/denetleyicidurum` | Bölge denetleyicisi (Inspector) atama/durum |

### 🎧 HUD / İletişim (client)
| Komut | Açıklama |
|---|---|
| `/hud` | Taktik HUD panelini aç/kapat |
| `/comintpanel` | COMINT (telsiz/telefon) panelini aç |
| `/baronterminali` | F10 Baron Terminali |
| `/silahtahliye` | Silah tahliye progressCircle'ı başlatır |
| `/muhafizcagir`, `/muhafizsalla` | Paralı asker (mercenary) çağır/gönder |

> Yukarıdaki tablolarda **olmayan** komutlar (adli/`forensics.lua`, işe alım/`recruitment.lua`, yara sistemi/`wound_system.lua`, vb. içindeki onlarca test komutu gibi) doğrudan ilgili sunucu dosyasında `RegisterCommand(` araması yaparak bulunabilir.

---

## ⚠️ Bilinen Konular

- `ox_target` bağımlılığı bildirilmiş ama kod tabanında doğrudan export çağrısına rastlanmadı (bkz. Zorunlu Bağımlılıklar notu).
- Vetting denetiminde bulunup düzeltilen 3 export kopukluğu (`Matrix.Bureau.GetHeat`, `Matrix.Diagnostics.RegisterCheck`, `Matrix.Wounds.IsBotPanicking`) artık düzeltildi — güncel sürümde 155/155 tanı geçmelidir.
- `_LogisticsPartialGrams` kesir akümülatörü **kasıtlı olarak yok**: `logistics.lua` hiçbir yerde sürekli/ondalıklı gram üretmiyor (yalnızca tam sayı torba/tuğla/adet), bu yüzden ilgili tanı kontrolü "ATLANDI" döner — bu bir hata değildir.
- `matrix_pending_refunds` şeması iki SQL dosyasında farklı tanımlı (bkz. Script Çakışma bölümü) — birleşik SQL dosyasını kullanmak bunu otomatik çözer.

---

## 🆕 Son Sürüm Notları

- **client/matrix_events_handler.lua**: 20 `matrix:client:*` event'inin tamamı gerçek sunucu tetikleyicilerine (`main.lua`, `market.lua`, `recruitment.lua`, `logistics.lua`, `cognition_core.lua`, `workbench.lua`) karşı doğrulandı; payload şekilleri artık tahmin değil.
- **sql/matrix_v3_ultimate_combined.sql**: 5 fazın tamamını doğru bağımlılık sırasıyla birleştiren tek-dosya migration.
- **server/bureau.lua**: `Matrix.Bureau.GetHeat` eklendi (8 çağrı noktasını aynı anda düzeltti).
- **server/matrix_diagnostics.lua**: `Matrix.Diagnostics.RegisterCheck` dışa açıldı; `_SafeHandler` sayım kontrolündeki yanlış-pozitif düzeltildi; `_LogisticsPartialGrams` kontrolü dürüst "ATLANDI" davranışına kavuştu.
- **server/wound_system.lua**: `Matrix.Wounds.IsBotPanicking` eklendi (mevcut cortisol/panik terminolojisiyle tutarlı).
