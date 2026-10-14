-- =====================================================================
-- ★★★ BÖLÜM 0 — RUNTIME-CREATED MISSING TABLES (PRE-MIGRATION) ★★★
-- Bu tablolar normalde Lua kodunun runtime'ında (kitchen.lua,
-- botany_core.lua, odor_core.lua, prop_registry.lua, crack_chemistry.lua,
-- meth_chemistry.lua, botany_autonomy.lua) CREATE TABLE IF NOT EXISTS ile
-- oluşturulur. Ancak MASTER SQL çalıştırıldığında bu tablolar henüz
-- yoksa, sonraki ALTER'lar "Table doesn't exist" hatası verir.
-- Bu blok, o sorunu KÖKTEN çözer: tüm bağımlı tabloları EN BAŞTA kurar.
-- Idempotent (IF NOT EXISTS) — güvenle birden fazla çalıştırılabilir.
-- =====================================================================

SET FOREIGN_KEY_CHECKS = 0;

-- ── KITCHEN / BOTANY (Faz 6) ──
CREATE TABLE IF NOT EXISTS `matrix_botany_cabinets` (
    `trap_house_id` INT PRIMARY KEY,
    `plant_stage` INT DEFAULT 0,
    `plant_ph` FLOAT DEFAULT 6.0,
    `wind_speed` FLOAT DEFAULT 0.0,
    `carbon_filter_life` FLOAT DEFAULT 1.00,
    `growth_progress` FLOAT DEFAULT 0.00,
    `status` VARCHAR(24) DEFAULT 'idle',
    `target_ph` FLOAT DEFAULT 6.0,
    `fan_speed` FLOAT DEFAULT 2.5
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `matrix_botany_state` (
    `trap_house_id` INT PRIMARY KEY,
    `growth_percent` FLOAT NOT NULL DEFAULT 0.0,
    `water_level` FLOAT NOT NULL DEFAULT 100.0,
    `leaf_decay` FLOAT NOT NULL DEFAULT 0.0,
    `ph_level` FLOAT NOT NULL DEFAULT 6.25,
    `infestation_state` TINYINT NOT NULL DEFAULT 0,
    `infestation_started` BIGINT NULL,
    `last_cycle_time` BIGINT NOT NULL DEFAULT 0,
    `crop_generation` INT NOT NULL DEFAULT 0,
    `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `matrix_odor_state` (
    `trap_house_id` INT PRIMARY KEY,
    `filter_durability` FLOAT NOT NULL DEFAULT 0.0,
    `filter_active` TINYINT(1) NOT NULL DEFAULT 0,
    `mask_until_epoch` BIGINT NULL,
    `last_filter_tick` BIGINT NOT NULL DEFAULT 0,
    `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ── PROP REGISTRY (Session 4.99) ──
CREATE TABLE IF NOT EXISTS `matrix_deployed_props` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `trap_house_id` INT NOT NULL,
    `kind` VARCHAR(32) NOT NULL,
    `coord_x` FLOAT NOT NULL,
    `coord_y` FLOAT NOT NULL,
    `coord_z` FLOAT NOT NULL,
    `heading` FLOAT NOT NULL DEFAULT 0.0,
    `deployed_by` VARCHAR(50) NULL,
    `active` TINYINT(1) NOT NULL DEFAULT 1,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_prop_house` (`trap_house_id`, `kind`, `active`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ── CRACK / METH / BOTANY AUTONOMY OPS (Session 4.99) ──
CREATE TABLE IF NOT EXISTS `matrix_crack_operations` (
    `id` BIGINT NOT NULL AUTO_INCREMENT,
    `agent_id` INT NOT NULL,
    `cell_id` INT NOT NULL,
    `cocaine_mg` FLOAT NOT NULL DEFAULT 0.0,
    `bicarbonate_mg` FLOAT NOT NULL DEFAULT 0.0,
    `dev_value` FLOAT NOT NULL DEFAULT 0.0,
    `agent_iq` FLOAT NOT NULL DEFAULT 100.0,
    `started_epoch` BIGINT NOT NULL,
    `ends_epoch` BIGINT NOT NULL,
    `status` VARCHAR(20) NOT NULL DEFAULT 'processing',
    `outcome` VARCHAR(32) NULL,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_crack_status` (`status`),
    KEY `idx_crack_agent` (`agent_id`),
    KEY `idx_crack_cell` (`cell_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `matrix_meth_operations` (
    `id` BIGINT NOT NULL AUTO_INCREMENT,
    `agent_id` INT NOT NULL,
    `cell_id` INT NOT NULL,
    `methylamine_mg` FLOAT NOT NULL DEFAULT 0.0,
    `phenylacetone_mg` FLOAT NOT NULL DEFAULT 0.0,
    `purity_drop` FLOAT NOT NULL DEFAULT 0.0,
    `toxicity` FLOAT NOT NULL DEFAULT 0.0,
    `skill_chemistry` FLOAT NOT NULL DEFAULT 0.0,
    `started_epoch` BIGINT NOT NULL,
    `ends_epoch` BIGINT NOT NULL,
    `status` VARCHAR(20) NOT NULL DEFAULT 'processing',
    `outcome` VARCHAR(32) NULL,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_meth_status` (`status`),
    KEY `idx_meth_agent` (`agent_id`),
    KEY `idx_meth_cell` (`cell_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `matrix_botany_autonomy_ops` (
    `id` BIGINT NOT NULL AUTO_INCREMENT,
    `agent_id` INT NOT NULL,
    `cell_id` INT NOT NULL,
    `gel_ml` FLOAT NOT NULL DEFAULT 0.0,
    `nitrogen_mg` FLOAT NOT NULL DEFAULT 0.0,
    `coeff` FLOAT NOT NULL DEFAULT 1.0,
    `started_epoch` BIGINT NOT NULL,
    `ends_epoch` BIGINT NOT NULL,
    `status` VARCHAR(20) NOT NULL DEFAULT 'processing',
    `outcome` VARCHAR(32) NULL,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_botany_status` (`status`),
    KEY `idx_botany_agent` (`agent_id`),
    KEY `idx_botany_cell` (`cell_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ── PLAYER TELEMETRY (Session 1 ek) ──
CREATE TABLE IF NOT EXISTS `matrix_player_telemetry` (
    `citizenid`        VARCHAR(50) NOT NULL,
    `active_hours`     TEXT        NULL,
    `preferred_zone`   INT         NULL,
    `aggression_index` FLOAT       NOT NULL DEFAULT 0.0,
    `escape_pattern`   FLOAT       NOT NULL DEFAULT 0.5,
    `spend_rate`       FLOAT       NOT NULL DEFAULT 0.0,
    `death_frequency`  FLOAT       NOT NULL DEFAULT 0.0,
    `trade_balance`    FLOAT       NOT NULL DEFAULT 0.0,
    `updated_at`       DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`citizenid`),
    KEY `idx_matrix_player_telemetry_preferred_zone` (`preferred_zone`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

SET FOREIGN_KEY_CHECKS = 1;

-- =====================================================================
-- ★★★ BÖLÜM 0 SONU — Devam: Aşağıdaki orijinal MASTER içeriği ★★★
-- =====================================================================




-- =====================================================================
-- ★★★ matrix_v3_ultimate_combined.sql — TEK DOSYA MASTER MIGRATION ★★★
--
-- vbs_core_matrix'in Faz 1-5 semasinin BIRLESTIRILMIS, TEK-CALISTIRMA
-- halidir. Kaynak 5 dosyanin (matrix_financial_core.sql,
-- matrix_bot_cognition.sql, phase3_persistent_vehicles.sql,
-- phase4_hardcore_friction.sql, phase5_coercion_matrix.sql) TAMAMI,
-- HICBIR SATIR ATLANMADAN, asagidaki SIRAYLA konsolide edildi.
--
-- SIRA NEDEN BOYLE (bagimlilik analizi):
--   1) matrix_financial_core.sql   -- matrix_forensic_evidence ve
--      matrix_cctv_logs dahil TUM temel semayi kurar. phase4 ve phase5
--      bu iki tabloyu ALTER TABLE ile genisletir; bu dosya olmadan
--      o ALTER'lar hedef tablo yokken calisir ve hata verir.
--   2) matrix_bot_cognition.sql    -- bagimsiz (Faz 1, kendi tablosu).
--   3) phase3_persistent_vehicles.sql -- bagimsiz tablolar kurar.
--   4) phase4_hardcore_friction.sql   -- (1)'in kurdugu matrix_cctv_logs
--      ve matrix_forensic_evidence'i ALTER eder -- (1)'den SONRA gelmeli.
--   5) phase5_coercion_matrix.sql     -- (1)'in kurdugu
--      matrix_forensic_evidence'i ALTER eder -- (1)'den SONRA gelmeli.
--
-- BILINEN KASITLI CAKISMA (zarasiz): matrix_pending_refunds hem (1)'de
-- (id INT, amount DECIMAL(12,2), resolved/resolved_by/resolved_at
-- alanlariyla TAM cozum-takip semasi) hem (3)'te (id BIGINT, amount
-- DECIMAL(15,2), cozum-takip alanlari YOK, basit orphan-refund defteri)
-- CREATE TABLE IF NOT EXISTS ile tanimlaniyor. (3)'un kendi yorumu bunu
-- ACIKCA bekliyor: "Bu tablo zaten baska bir modulde olusturulmus
-- olabilir; IF NOT EXISTS ile idempotent birakildi." Bu dosyada (1) ILK
-- calistigi icin onun TAM sema kazanir; (3)'unki IF NOT EXISTS sayesinde
-- sessiz ve zararsiz bir no-op'a duser -- tam olarak (3)'un yazarinin
-- amacladigi davranis.
--
-- IDEMPOTENCY: her CREATE TABLE => IF NOT EXISTS, her ALTER TABLE ADD
-- COLUMN => IF NOT EXISTS (MariaDB 10.4+ / MySQL 8.0+ sozdizimi). Bu
-- script guvenle birden fazla kez calistirilabilir.
--
-- Bu dosya SADECE bu 5 kaynagi birlestirir -- hicbir tablo/kolon EKLENMEDI,
-- SILINMEDI veya DEGISTIRILMEDI. Her bolumun altinda kaynak dosya adi
-- izlenebilirlik icin belirtilmistir.
-- =====================================================================

-- =======================================================================
-- BÖLÜM 1/5 — KAYNAK: sql/matrix_financial_core.sql (1477 satır, birebir)
-- =======================================================================

-- =====================================================================
-- ★★★ MATRIX FINANCIAL CORE — TEK DOSYA KONSOLIDASYON MUHURU ★★★
-- sql/matrix_financial_core.sql
--
-- Bu dosya, projenin ONCEDEN 9 ayri dosyaya dagilmis TUM sema gecmisinin
-- BIRLESTIRILMIS HALIDIR -- artik sql/ klasorunde BASKA HICBIR .sql dosyasi
-- YOKTUR, tek calistirma adimi budur:
--   1) matrix.sql              (temel sema, Katman 1-5)
--   2) layer5_ultimate.sql     (Katman 5 Ultimate -- Co-Op/SIGINT/COMINT)
--   3) layer6_trap_house.sql   (Katman 6 -- Trap House ic mekan/tezgah)
--   4) layer7_faz1.sql         (Katman 7 [T4] Faz 1 -- Buro Kilidi + Hub'lar)
--   5) layer7_faz3.sql         (Katman 7 [T4] Faz 3 -- loyalty_base)
--   6) matrix_security_hardening.sql (SEC-2 offline iade defteri)
--   7) matrix_cctv_network.sql (mobese agi -- matrix_cctv_logs)
--   8) layer_regression_schema.sql  (9 geri-enjekte DB kontrolu + Adli RPG/
--      Kor Nokta semasi -- /davaac, /telefonuyoket, Koma Modu, FragmentTerritory)
--   9) layer_splinter_cells.sql (Otonom Alt Hucre Bolunmesi -- Splinter Cells)
-- Ilk 7 bolum, hangi eski dosyadan geldigini gosteren bir "★ KAYNAK"
-- basligiyla ayrilmistir; o basliklarin ALTINDAKI icerik o dosyalarin
-- ORIJINAL halinden TEK BIR SATIR BILE ATLANMADAN/DEGISTIRILMEDEN
-- birebir tasindi. Son iki bolum bu oturumda eklenen YENI migration'lardir
-- (asagida da "★ KAYNAK" basligiyla ayri ayri isaretlenmistir).
--
-- ★ BILINCLI DISLAMA NOTU: bu dosyaya elle yapistirilan bir onceki taslakta
-- ("FAZ 2/3/KATMAN14 KONSOLIDASYON DUZELTME") matrix_purchase_logs/
-- matrix_trial_records/matrix_gang_learning_core/matrix_legal_plate_evidence
-- icin BU dosyadaki (8. bolum) semadan FARKLI kolon adlari/tipleri ve
-- RecordAuditableInvoice/ProcessLegalPlateALPR/GetEvidenceLinesForDefendant
-- gibi BU DALDA (bureau.lua) MEVCUT OLMAYAN fonksiyonlara atif iceriyordu.
-- Bu dalin GERCEKTE calisan kodu (server/bureau.lua Matrix.Bureau.OpenTrial/
-- RecordTrialResponse/ExecuteVerdict/SabotagePhoneLine/RunHourlyFinancialAudit,
-- server/district_hubs.lua FragmentTerritory) 8. bolumdeki semaya yazar/okur
-- -- bu yuzden o alternatif taslak BURAYA DAHIL EDILMEDI (sessizce
-- calisan kodu kirmamak icin). O taslak ayri, daha genis bir "Paravan
-- Isletme/Mali Denetim" ozelligiyse, ayri bir migration + karsilik gelen
-- Lua degisiklikleriyle BIRLIKTE getirilmelidir.
--
-- CALISTIRMA: bu TEK dosyayi, dogrudan (bastan sona) sirayla import edin.
-- Ayri ayri calistirma adimi ARTIK YOKTUR.
-- =====================================================================



-- =======================================================================
-- ★ KAYNAK: sql/matrix.sql (orijinal icerik, birebir asagida, hicbir satir atlanmadi)
-- =======================================================================

-- =====================================================================
-- MATRIX SCHEMA v3 — Katman 5 (Qbox Co-op Kartel Hiyerarşisi & Piyasa)
-- Katman 1-2-3-4-5 Birlesik Motor - Kalici Veri Tabani
--
-- ★ DEĞİŞİKLİK NOTU (v2 → v3):
--   (1) KATMAN 5 tabloları eklendi: matrix_hierarchy (co-op rütbe),
--       matrix_market_zones (bölgesel piyasa fiyat çarpanı), matrix_cash_decay
--       (kirlenen nakit sönümlenmesi). v2'nin "ON UPDATE CURRENT_TIMESTAMP
--       KULLANMA" politikası aynen sürdürüldü — `updated_at` uygulama
--       katmanında (market.lua) her UPDATE/UPSERT'te explicit NOW() ile
--       yazılır.
--   (2) matrix_cash_decay, matrix_trap_houses'a FK ile bağlı olduğundan
--       FOREIGN_KEY_CHECKS=0 sarması İÇİNE, diğer Katman 1-4 tablolarından
--       SONRA eklendi (parent zaten mevcut).
--   (3) Katman 1-4 tabloları/yorumları HİÇ DEĞİŞMEDİ (aşağıdaki v1→v2 notu
--       olduğu gibi korunmuştur).
--
-- ★ DEĞİŞİKLİK NOTU (v1 → v2):
--   (1) Tüm `DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP`
--       kombinasyonları KALDIRILDI. Neden: bazı MariaDB/MySQL derlemeleri
--       bu kombinasyonu kolon-tanımı parser'ında reddediyor ve CREATE
--       TABLE sessizce başarısız oluyordu → matrix_fleet ve
--       matrix_supplier_trust gibi Katman 4 tabloları hiç yaratılmıyordu.
--       Uygulama katmanı `updated_at = NOW()`'u her UPDATE/UPSERT
--       sorgusunda explicit gönderiyor (main.lua BOT_UPSERT_TAIL,
--       logistics.lua FlushDirtyFleet / FlushDirtySupplierTrust), bu
--       yüzden DB-seviyesi auto-update KAYBI YOKTUR.
--
--   (2) Tüm tablolar parent→child sırasına göre yeniden dizildi:
--       matrix_trap_houses  →  pattern_log/bureau_intel/raid_log/...
--       matrix_ballistic_weapons  →  matrix_forensic_evidence
--       matrix_bots  →  matrix_snitch_events
--
--   (3) `SET FOREIGN_KEY_CHECKS = 0` sarması eklendi: mevcut bir şemayı
--       yeniden import ederken FK ihlali yaşanmaz. Sonunda tekrar 1'e
--       döndürülür.
--
--   (4) Tüm kolon tipleri FULL MySQL 5.7 / MariaDB 10.x uyumludur.
--       DECIMAL ve ENUM sınırları korunmuştur.
--
-- ★ ADLİ KAYIT POLİTİKASI (DOKUNULMADI):
--   matrix_forensic_evidence, matrix_ballistic_weapons, matrix_touch_log,
--   matrix_alpr_hits, matrix_vehicle_seizures, matrix_dead_drop_events,
--   matrix_raid_log, matrix_livestream_events — asla silinmez, yalnızca
--   eklenir. Uygulama katmanı DELETE yalnızca matrix_bots ve matrix_fleet
--   için çağırır (hard-delete politika).
--
-- ★ KATMAN 8 NOTU (Hard-Wipe / E_total): İstek metninde tanımlanan "Ortak
--   Risk Kontratı" (çete-çapında kümülatif kanıt matrisi tetiklendiğinde
--   TÜM oyuncu verisinin aynı saniyede DROP edilmesi) BİLİNÇLİ OLARAK bu
--   şemaya EKLENMEDİ. Eşik/kapsam/hangi tabloların etkileneceği tanımsız;
--   tanımsız bir toplu-silme mekanizmasını tahminle şemaya kilitlemek,
--   yanlış bir tasarımı geri alınması güç hale getirir. Katman 8 netleşince
--   ayrı bir migration olarak eklenmelidir.
-- =====================================================================


SET FOREIGN_KEY_CHECKS = 0;


-- =====================================================================
-- KATMAN 1: CORE MATRIX  (Kalıcı Kimlik ve Biyoloji)
-- =====================================================================


-- ---------------------------------------------------------------------
-- Bot / Dealer Kalıcı Kimlik ve Biyoloji Profili
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_bots` (
    `id`                         INT          NOT NULL,
    `dna_id`                     VARCHAR(64)  NOT NULL,
    `name`                       VARCHAR(100) NOT NULL,
    `role`                       VARCHAR(32)  NOT NULL DEFAULT 'runner',
    `status`                     ENUM('active','burned','deceased','retired') NOT NULL DEFAULT 'active',
    `fear_factor`                FLOAT        NOT NULL DEFAULT 0.0,
    `resilience`                 FLOAT        NOT NULL DEFAULT 0.5,
    `snitch_tendency`            FLOAT        NOT NULL DEFAULT 0.0,
    `economic_pressure`          FLOAT        NOT NULL DEFAULT 0.0,
    `cognitive_shifter`          FLOAT        NOT NULL DEFAULT 0.5,
    `skill_chemistry`            FLOAT        NOT NULL DEFAULT 0.3,
    `skill_cyber`                FLOAT        NOT NULL DEFAULT 0.0,
    `skill_logistics`            FLOAT        NOT NULL DEFAULT 0.0,
    `fatigue_level`              FLOAT        NOT NULL DEFAULT 0.0,
    `cortisol_level`             FLOAT        NOT NULL DEFAULT 0.0,
    `withdrawal_index`           FLOAT        NOT NULL DEFAULT 0.0,
    `addiction_level`            FLOAT        NOT NULL DEFAULT 0.0,
    `base_cortisol_recovery_rate` FLOAT       NOT NULL DEFAULT 0.05,
    `trap_house_id`              INT          NULL,
    `created_at`                 DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at`                 DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_matrix_bots_dna_id` (`dna_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Oyuncu Kalıcı Bio-Durumu (fingerprint/kortizol formülleri için)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_player_state` (
    `citizenid`      VARCHAR(50) NOT NULL,
    `cortisol_level` FLOAT       NOT NULL DEFAULT 0.0,
    `fatigue_level`  FLOAT       NOT NULL DEFAULT 0.0,
    `updated_at`     DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`citizenid`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Kalıcı Balistik Silah Kaydı (yiv-set imza kodu ile)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_ballistic_weapons` (
    `ballistic_id`            VARCHAR(64) NOT NULL,
    `weapon_serial`           VARCHAR(64) NOT NULL,
    `wear_level`              FLOAT       NOT NULL DEFAULT 0.0,
    `sealed_as_crime_weapon`  TINYINT(1)  NOT NULL DEFAULT 0,
    `seal_certainty`          FLOAT       NULL,
    `first_registered`        DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`ballistic_id`),
    UNIQUE KEY `uq_matrix_ballistic_weapon_serial` (`weapon_serial`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Kalıcı Adli Kanıt Veri Tabanı (asla silinmez)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_forensic_evidence` (
    `id`                      INT          NOT NULL AUTO_INCREMENT,
    `ballistic_id`            VARCHAR(64)  NOT NULL,
    `evidence_type`           VARCHAR(32)  NOT NULL DEFAULT 'casing',
    `striation_quality`       FLOAT        NOT NULL,
    `fingerprint_id`          VARCHAR(64)  NOT NULL,
    `fingerprint_quality`     FLOAT        NOT NULL,
    `match_certainty`         FLOAT        NOT NULL,
    `sealed_as_crime_weapon`  TINYINT(1)   NOT NULL DEFAULT 0,
    `coords_x`                FLOAT        NOT NULL DEFAULT 0.0,
    `coords_y`                FLOAT        NOT NULL DEFAULT 0.0,
    `coords_z`                FLOAT        NOT NULL DEFAULT 0.0,
    `created_at`              DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_forensic_evidence_ballistic_id` (`ballistic_id`),
    CONSTRAINT `fk_matrix_forensic_evidence_ballistic`
        FOREIGN KEY (`ballistic_id`) REFERENCES `matrix_ballistic_weapons` (`ballistic_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Dokunulan Nesneler - Genel Parmak İzi Günlüğü (asla silinmez)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_touch_log` (
    `id`                  INT          NOT NULL AUTO_INCREMENT,
    `fingerprint_id`      VARCHAR(64)  NOT NULL,
    `fingerprint_quality` FLOAT        NOT NULL,
    `inventory_id`        VARCHAR(64)  NOT NULL,
    `slot_id`             INT          NOT NULL,
    `created_at`          DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_touch_log_fingerprint_id` (`fingerprint_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Karanlık Mülakat - Müşteri Havuzu (deterministik trait çıkarımı)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_customer_pool` (
    `citizenid`                  VARCHAR(50)  NOT NULL,
    `name`                       VARCHAR(100) NOT NULL,
    `police_encounters_nearby`   INT          NOT NULL DEFAULT 0,
    `completed_deals`            INT          NOT NULL DEFAULT 0,
    `times_reported`             INT          NOT NULL DEFAULT 0,
    `failed_payments`            INT          NOT NULL DEFAULT 0,
    `chemistry_hints`            INT          NOT NULL DEFAULT 0,
    `addiction_level`            FLOAT        NOT NULL DEFAULT 0.0,
    `promoted_to_candidate`      TINYINT(1)   NOT NULL DEFAULT 0,
    `created_at`                 DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`citizenid`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Karanlık Mülakat - Sorgu Oturumu Sonuç Günlüğü
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_recruitment_sessions` (
    `id`                     INT          NOT NULL AUTO_INCREMENT,
    `candidate_citizenid`    VARCHAR(50)  NOT NULL,
    `fear_factor`            FLOAT        NOT NULL,
    `resilience`             FLOAT        NOT NULL,
    `lies_told`              INT          NOT NULL DEFAULT 0,
    `confessions`            INT          NOT NULL DEFAULT 0,
    `outcome`                ENUM('recruited','released','burned') NOT NULL,
    `created_at`             DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_recruitment_sessions_candidate` (`candidate_citizenid`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- =====================================================================
-- KATMAN 2: THE BUREAU  (Trap House + Desifre + Baskin + Yayin)
-- =====================================================================


-- ---------------------------------------------------------------------
-- Trap House Kayıtları (üçgenleme/desifre hedefleri)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_trap_houses` (
    `id`                    INT          NOT NULL AUTO_INCREMENT,
    `label`                 VARCHAR(100) NOT NULL,
    `coord_x`               FLOAT        NOT NULL,
    `coord_y`               FLOAT        NOT NULL,
    `coord_z`               FLOAT        NOT NULL,
    `decryption_confidence` FLOAT        NOT NULL DEFAULT 0.0,
    `cyber_leak_intensity`  FLOAT        NOT NULL DEFAULT 0.0,
    `raid_ordered`          TINYINT(1)   NOT NULL DEFAULT 0,
    `last_raid_at`          DATETIME     NULL,
    `created_at`            DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Pattern Desifre Dongusu - Saat/Gun Kalibi Gunlugu
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_pattern_log` (
    `id`               INT      NOT NULL AUTO_INCREMENT,
    `trap_house_id`    INT      NOT NULL,
    `day_of_week`      TINYINT  NOT NULL,
    `hour_of_day`      TINYINT  NOT NULL,
    `occurrence_count` INT      NOT NULL DEFAULT 1,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_matrix_pattern_log_bucket` (`trap_house_id`, `day_of_week`, `hour_of_day`),
    CONSTRAINT `fk_matrix_pattern_log_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Buro Istihbarat Katmani (ucgenleme / siber sizinti yogunlugu)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_bureau_intel` (
    `id`             INT          NOT NULL AUTO_INCREMENT,
    `trap_house_id`  INT          NOT NULL,
    `category`       ENUM('triangulation','cyber_leak','pattern') NOT NULL,
    `intensity`      FLOAT        NOT NULL DEFAULT 0.0,
    `updated_at`     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_matrix_bureau_intel_bucket` (`trap_house_id`, `category`),
    CONSTRAINT `fk_matrix_bureau_intel_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Fiziksel Safak Baskini Gunlugu - murettebat/breach/sonuc kaydi
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_raid_log` (
    `id`                             INT          NOT NULL AUTO_INCREMENT,
    `trap_house_id`                  INT          NOT NULL,
    `squad_size`                     INT          NOT NULL,
    `breach_method`                  VARCHAR(32)  NOT NULL DEFAULT 'ram',
    `decryption_confidence_at_raid`  FLOAT        NOT NULL,
    `escape_window_seconds`          INT          NOT NULL DEFAULT 0,
    `outcome`                        ENUM('pending','captured','escaped','eliminated') NOT NULL DEFAULT 'pending',
    `created_at`                     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `resolved_at`                    DATETIME     NULL,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_raid_log_trap_house` (`trap_house_id`),
    CONSTRAINT `fk_matrix_raid_log_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- qb-phone Canli Yayin / Siber Propaganda Gunlugu (asla silinmez)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_livestream_events` (
    `id`               INT          NOT NULL AUTO_INCREMENT,
    `citizenid`        VARCHAR(50)  NOT NULL,
    `duration_seconds` INT          NOT NULL DEFAULT 0,
    `hype_multiplier`  FLOAT        NOT NULL DEFAULT 1.0,
    `heat_added`       FLOAT        NOT NULL DEFAULT 0.0,
    `trap_house_id`    INT          NULL,
    `created_at`       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- =====================================================================
-- KATMAN 3: İHANET & MUTFAK
-- =====================================================================


-- ---------------------------------------------------------------------
-- Ihanet & Muhbirlik Gunlugu
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_snitch_events` (
    `id`             INT         NOT NULL AUTO_INCREMENT,
    `bot_id`         INT         NOT NULL,
    `trap_house_id`  INT         NOT NULL,
    `snitch_index`   FLOAT       NOT NULL,
    `lied`           TINYINT(1)  NOT NULL DEFAULT 0,
    `created_at`     DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_snitch_events_bot` (`bot_id`),
    CONSTRAINT `fk_matrix_snitch_events_bot`
        FOREIGN KEY (`bot_id`) REFERENCES `matrix_bots` (`id`),
    CONSTRAINT `fk_matrix_snitch_events_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Mutfak Motoru - Seyreltme/Kesme Isletim Gunlugu
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_kitchen_batches` (
    `id`                           INT          NOT NULL AUTO_INCREMENT,
    `trap_house_id`                INT          NOT NULL,
    `actor_identifier`             VARCHAR(64)  NOT NULL,
    `raw_weight`                   FLOAT        NOT NULL,
    `raw_purity`                   FLOAT        NOT NULL,
    `agent_weight`                 FLOAT        NOT NULL,
    `theoretical_purity`           FLOAT        NOT NULL,
    `error_coefficient`            FLOAT        NOT NULL,
    `output_purity`                FLOAT        NOT NULL,
    `waste_volume`                 FLOAT        NOT NULL,
    `theft_amount`                 FLOAT        NOT NULL DEFAULT 0.0,
    `rival_infiltration_triggered` TINYINT(1)   NOT NULL DEFAULT 0,
    `created_at`                   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_kitchen_batches_trap_house` (`trap_house_id`),
    CONSTRAINT `fk_matrix_kitchen_batches_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- =====================================================================
-- KATMAN 4: İLLEGAL FİLO + TOPTANCI İLİŞKİ MATRİSİ + DEAD DROP
-- =====================================================================


-- ---------------------------------------------------------------------
-- İllegal Filo - Aktif Araç Havuzu. Bir araç ele geçirilirse (çatışma/
-- baskın) bu tablodan hard-delete edilir; kalıcı adli mühür ayrı olarak
-- matrix_vehicle_seizures'a yazılır.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_fleet` (
    `id`                      INT          NOT NULL AUTO_INCREMENT,
    `plate`                   VARCHAR(32)  NOT NULL,
    `vehicle_class`           ENUM('motorbike','car') NOT NULL DEFAULT 'car',
    `vin_status`              ENUM('factory','scratched','hot') NOT NULL DEFAULT 'hot',
    `vehicle_wear`            FLOAT        NOT NULL DEFAULT 0.0,
    `registered_by_citizenid` VARCHAR(50)  NULL,
    `assigned_bot_id`         INT          NULL,
    `assignment_mode`         ENUM('permanent','temporary') NULL,
    `verified_stolen_plate`   TINYINT(1)   NOT NULL DEFAULT 0,
    `created_at`              DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at`              DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_matrix_fleet_plate` (`plate`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Büro ALPR / Görsel Eşkal Eşleşme Günlüğü (asla silinmez).
-- Plaka + dealer fingerprint_dna_id + organizasyon imzası bağlanır.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_alpr_hits` (
    `id`                     INT          NOT NULL AUTO_INCREMENT,
    `plate`                  VARCHAR(32)  NOT NULL,
    `fingerprint_dna_id`     VARCHAR(64)  NOT NULL,
    `organization_signature` VARCHAR(50)  NOT NULL,
    `trap_house_id`          INT          NOT NULL,
    `created_at`             DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_alpr_hits_plate` (`plate`),
    CONSTRAINT `fk_matrix_alpr_hits_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Ele Geçirilen Araç Mührü - kalıcı kanıt katsayısı (asla silinmez).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_vehicle_seizures` (
    `id`                     INT          NOT NULL AUTO_INCREMENT,
    `plate`                  VARCHAR(32)  NOT NULL,
    `vin_status`             ENUM('factory','scratched','hot') NOT NULL,
    `vehicle_wear`           FLOAT        NOT NULL DEFAULT 0.0,
    `fingerprint_dna_id`     VARCHAR(64)  NOT NULL,
    `organization_signature` VARCHAR(50)  NOT NULL,
    `seizure_cause`          VARCHAR(32)  NOT NULL DEFAULT 'unknown',
    `seal_certainty`         FLOAT        NOT NULL,
    `coords_x`               FLOAT        NOT NULL DEFAULT 0.0,
    `coords_y`               FLOAT        NOT NULL DEFAULT 0.0,
    `coords_z`               FLOAT        NOT NULL DEFAULT 0.0,
    `created_at`              DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_vehicle_seizures_plate` (`plate`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Toptancı Güven Matrisi - oyuncu/toptancı ilişkisi kalıcıdır.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_supplier_trust` (
    `citizenid`      VARCHAR(50) NOT NULL,
    `supplier_id`    INT         NOT NULL,
    `trust`          FLOAT       NOT NULL DEFAULT 0.5,
    `late_payments`  INT         NOT NULL DEFAULT 0,
    `forensic_leaks` INT         NOT NULL DEFAULT 0,
    `created_at`     DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at`     DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`citizenid`, `supplier_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Dead Drop Teslim Alma Günlüğü (asla silinmez)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_dead_drop_events` (
    `id`                    INT          NOT NULL AUTO_INCREMENT,
    `drop_id`               INT          NOT NULL,
    
        `supplier_id`           INT          NOT NULL,
    `citizenid`             VARCHAR(50)  NOT NULL,
    `heat_at_pickup`        FLOAT        NOT NULL DEFAULT 0.0,
    `forensic_trace_left`   TINYINT(1)   NOT NULL DEFAULT 0,
    `created_at`            DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_dead_drop_events_drop` (`drop_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- =====================================================================
-- KATMAN 5: QBOX CO-OP KARTEL HİYERARŞİSİ + BÖLGESEL PİYASA +
-- KILCAL DAMAR HARDCORE MEKANİKLER
-- =====================================================================


-- ---------------------------------------------------------------------
-- Co-op Kartel Rütbe Ataması (CitizenID bazlı, kalıcı)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_hierarchy` (
    `citizenid`   VARCHAR(50) NOT NULL,
    `rank`        ENUM('Leader','Logistics_Officer','Chemist') NOT NULL DEFAULT 'Chemist',
    `assigned_by` VARCHAR(50) NULL,
    `created_at`  DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at`  DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`citizenid`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Bölgesel Piyasa - anlık fiyat çarpanı / reddedilen parti sayacı
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_market_zones` (
    `zone_id`          INT      NOT NULL,
    `price_multiplier` FLOAT    NOT NULL DEFAULT 1.0,
    `rejected_streak`  INT      NOT NULL DEFAULT 0,
    `updated_at`       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`zone_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Kirlenen Nakit Sönümlenmesi - trap house başına biriken kirli nakit ve
-- ilk yatırılma zamanı (adli koku/seri no izi τ=90 gün formülü buradan
-- türetilir; bkz. market.lua Matrix.CashDecay).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_cash_decay` (
    `trap_house_id`  INT      NOT NULL,
    `dirty_amount`   FLOAT    NOT NULL DEFAULT 0.0,
    `deposited_at`   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at`     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`trap_house_id`),
    CONSTRAINT `fk_matrix_cash_decay_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- =====================================================================
-- FOREIGN KEY CHECK'LERİNİ YENİDEN AÇ
-- =====================================================================
SET FOREIGN_KEY_CHECKS = 1;


-- =====================================================================
-- DOĞRULAMA SORGUSU (opsiyonel — çalıştırıldığında 22 dönmeli)
-- =====================================================================
-- SELECT COUNT(*) AS matrix_table_count
-- FROM information_schema.tables
-- WHERE table_schema = DATABASE()
--   AND table_name LIKE 'matrix\_%';


-- =====================================================================
-- BAKIM: Sıfırdan yeniden kurmak isterseniz aşağıdaki blok
-- (yalnızca FK sırasına göre tersten) DROP eder. Yorumdan çıkarıp
-- çalıştırın. Bu blok TÜM VERİYİ SİLER — dikkatli kullanın.
-- =====================================================================
-- SET FOREIGN_KEY_CHECKS = 0;
-- DROP TABLE IF EXISTS `matrix_cash_decay`;
-- DROP TABLE IF EXISTS `matrix_market_zones`;
-- DROP TABLE IF EXISTS `matrix_hierarchy`;
-- DROP TABLE IF EXISTS `matrix_livestream_events`;
-- DROP TABLE IF EXISTS `matrix_dead_drop_events`;
-- DROP TABLE IF EXISTS `matrix_supplier_trust`;
-- DROP TABLE IF EXISTS `matrix_vehicle_seizures`;
-- DROP TABLE IF EXISTS `matrix_alpr_hits`;
-- DROP TABLE IF EXISTS `matrix_fleet`;
-- DROP TABLE IF EXISTS `matrix_kitchen_batches`;
-- DROP TABLE IF EXISTS `matrix_snitch_events`;
-- DROP TABLE IF EXISTS `matrix_raid_log`;
-- DROP TABLE IF EXISTS `matrix_bureau_intel`;
-- DROP TABLE IF EXISTS `matrix_pattern_log`;
-- DROP TABLE IF EXISTS `matrix_trap_houses`;
-- DROP TABLE IF EXISTS `matrix_recruitment_sessions`;
-- DROP TABLE IF EXISTS `matrix_customer_pool`;
-- DROP TABLE IF EXISTS `matrix_touch_log`;
-- DROP TABLE IF EXISTS `matrix_forensic_evidence`;
-- DROP TABLE IF EXISTS `matrix_ballistic_weapons`;
-- DROP TABLE IF EXISTS `matrix_player_state`;
-- DROP TABLE IF EXISTS `matrix_bots`;


-- SET FOREIGN_KEY_CHECKS = 1;


-- =======================================================================
-- ★ KAYNAK: sql/layer5_ultimate.sql (orijinal icerik, birebir asagida, hicbir satir atlanmadi)
-- =======================================================================

-- =====================================================================
-- MATRIX SCHEMA — KATMAN 5 ULTIMATE EK MİGRASYONU (sql/layer5_ultimate.sql)
-- Co-Op & SIGINT/COMINT Bali-Logistics Matrix
--
-- ★ BU DOSYA TAMAMEN EKLEMELİDİR (ADDITIVE-ONLY):
--   matrix.sql'deki (v3) 16 tabloya HİÇBİRİNE DOKUNULMAZ — ALTER YOK,
--   DROP YOK, kolon eklenmedi. Yalnızca 4 YENİ tablo eklenir. matrix.sql'i
--   İMPORT ETTİKTEN SONRA bu dosyayı çalıştırın.
--
--   Bu dosya, matrix.sql ile AYNI konvansiyonları izler:
--     - ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
--     - "DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP" KULLANILMAZ
--       (bazı MariaDB/MySQL derlemelerinde CREATE TABLE'ı sessizce
--       başarısız kılıyordu — v1→v2 notu, bkz. matrix.sql). `updated_at`/
--       `flagged_at`/`assigned_at` uygulama katmanında (server/market.lua,
--       server/blackmarket.lua) her UPSERT'te explicit NOW() ile yazılır.
--     - Tablo/kolon adları geriye dönük `matrix_` önekini korur.
--
--   ★ KASITLI TASARIM KARARI — FK YOK: `matrix_zone_inspectors.bot_id` ve
--     `matrix_mole_flags.bot_id`, KASITLI OLARAK `matrix_bots.id`'ye FOREIGN
--     KEY İLE BAĞLANMAZ. Sebep: server/logistics.lua'nın Matrix.Logistics.
--     OnDealerEliminated'i (F10 "Operatif Tasfiye Et" -> /operatiftasfiye,
--     bkz. server/main.lua) matrix_bots satırını GERÇEK bir DELETE ile
--     kalıcı olarak siler (hard-delete politikası, matrix.sql başlığında
--     zaten tanımlı). Bir Inspector'a atanmış veya köstebek olarak
--     işaretlenmiş bir botu tasfiye etmek İSTİSNASIZ ÇALIŞMALIDIR — bir FK
--     kısıtı (varsayılan RESTRICT/NO ACTION) bu hard-delete'i SESSİZCE
--     BLOKE ederdi. RAM tarafında (server/market.lua Matrix.Inspector)
--     zaten stale bot_id'lere karşı dayanıklı: silinen bir bot bir
--     sonraki taramada otomatik olarak atamadan düşer (self-healing).
-- =====================================================================


SET FOREIGN_KEY_CHECKS = 0;


-- ---------------------------------------------------------------------
-- [U2] Karaborsa Ticaret Ağı - satın alma günlüğü (asla silinmez; mevcut
-- "adli kayıt politikası" ruhuna uygun kalıcı bir kâğıt izi).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_blackmarket_purchases` (
    `id`          INT          NOT NULL AUTO_INCREMENT,
    `citizenid`   VARCHAR(50)  NOT NULL,
    `item_type`   ENUM('vehicle','weapon','barrel','burner_phone') NOT NULL,
    `item_ref`    VARCHAR(64)  NOT NULL,
    `price_paid`  FLOAT        NOT NULL DEFAULT 0.0,
    `created_at`  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_blackmarket_purchases_citizenid` (`citizenid`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- [U4] SIGINT - Bölge Denetleyicisi (Inspector) ataması. Bölge başına
-- TEK aktif denetleyici (PRIMARY KEY = zone_id); yeniden atama UPSERT ile
-- öncekinin yerini alır.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_zone_inspectors` (
    `zone_id`                INT         NOT NULL,
    `bot_id`                 INT         NOT NULL,
    `assigned_by_citizenid`  VARCHAR(50) NULL,
    `assigned_at`            DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`zone_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- [U4] SIGINT - Köstebek/muhbir tarama sonucu kalıcı bülteni. Bir botun
-- Operatif Tasfiye Et ile arındırılmasından SONRA da (kanıt/denetim amaçlı)
-- kalır; matrix_bots.id hard-delete sonrası hiçbir zaman yeniden
-- kullanılmaz (Matrix.NextBotId monoton artar), bu yüzden stale satır bir
-- sonraki bot ile ASLA çakışmaz.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_mole_flags` (
    `bot_id`           INT      NOT NULL,
    `snitch_tendency`  FLOAT    NOT NULL DEFAULT 0.0,
    `flagged_at`       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`bot_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- [U6] Bölgesel Mali Rapor - bölge başına yuvarlanan (rolling) kâr/zarar
-- bilançosu. matrix_market_zones (fiyat çarpanı/ardarda-red) ile AYNI
-- zone_id uzayını paylaşır ama BAĞIMSIZ bir tablodur (o da zone_id'ye FK
-- taşımıyor — zone'lar Config.Market.Zones'ta statik tanımlı, ayrı bir
-- "zones" ebeveyn tablosu hiç var olmadı).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_zone_ledger` (
    `zone_id`            INT      NOT NULL,
    `sale_count`         INT      NOT NULL DEFAULT 0,
    `total_grams`        FLOAT    NOT NULL DEFAULT 0.0,
    `gross_revenue`      FLOAT    NOT NULL DEFAULT 0.0,
    `net_profit`         FLOAT    NOT NULL DEFAULT 0.0,
    `price_crash_count`  INT      NOT NULL DEFAULT 0,
    `updated_at`         DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`zone_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


SET FOREIGN_KEY_CHECKS = 1;


-- =====================================================================
-- DOĞRULAMA SORGUSU (opsiyonel — bu dosya çalıştırıldıktan sonra 4 dönmeli)
-- =====================================================================
-- SELECT COUNT(*) AS layer5_ultimate_table_count
-- FROM information_schema.tables
-- WHERE table_schema = DATABASE()
--   AND table_name IN (
--       'matrix_blackmarket_purchases',
--       'matrix_zone_inspectors',
--       'matrix_mole_flags',
--       'matrix_zone_ledger'
--   );


-- =====================================================================
-- BAKIM: Yalnızca bu migrasyonun eklediği 4 tabloyu geri almak isterseniz
-- (matrix.sql'in 16 tablosuna DOKUNMAZ). Yorumdan çıkarıp çalıştırın.
-- =====================================================================
-- SET FOREIGN_KEY_CHECKS = 0;
-- DROP TABLE IF EXISTS `matrix_zone_ledger`;
-- DROP TABLE IF EXISTS `matrix_mole_flags`;
-- DROP TABLE IF EXISTS `matrix_zone_inspectors`;
-- DROP TABLE IF EXISTS `matrix_blackmarket_purchases`;
-- SET FOREIGN_KEY_CHECKS = 1;


-- =======================================================================
-- ★ KAYNAK: sql/layer6_trap_house.sql (orijinal icerik, birebir asagida, hicbir satir atlanmadi)
-- =======================================================================

-- =====================================================================
-- MATRIX SCHEMA — KATMAN 6 EK MİGRASYONU (sql/layer6_trap_house.sql)
-- Siber-Taktik Operasyon ve Stratejik Trap House Mimarisi
--
-- ★ BU DOSYA TAMAMEN EKLEMELİDİR (ADDITIVE-ONLY):
--   matrix.sql (v3, 22 tablo) ve sql/layer5_ultimate.sql (4 tablo)
--   HİÇBİR ŞEKİLDE değiştirilmez — ALTER YOK, DROP YOK, kolon eklenmedi.
--   Yalnızca 3 YENİ tablo eklenir. matrix.sql VE layer5_ultimate.sql'i
--   İMPORT ETTİKTEN SONRA bu dosyayı çalıştırın.
--
--   Aynı konvansiyonlar korunur: ENGINE=InnoDB DEFAULT CHARSET=utf8mb4,
--   "ON UPDATE CURRENT_TIMESTAMP" KULLANILMAZ (uygulama katmanı NOW() ile
--   yazar), `matrix_` öneki korunur, FK'ler yalnızca gerçekten var olan
--   kalıcı ebeveyn tablolara (matrix_trap_houses) bağlanır.
-- =====================================================================


SET FOREIGN_KEY_CHECKS = 0;


-- ---------------------------------------------------------------------
-- [K6-4] Kapı Sürgü Tahkimatı — trap house başına TEK aktif seviye
-- (0-3). server/door_reinforcement.lua tarafından okunur/yazılır.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_door_reinforcement` (
    `trap_house_id` INT      NOT NULL,
    `level`         TINYINT  NOT NULL DEFAULT 0,
    `installed_by_citizenid` VARCHAR(50) NULL,
    `updated_at`    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`trap_house_id`),
    CONSTRAINT `fk_matrix_door_reinforcement_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- [K6-1] Rendezvous / Dead Drop teslimatı adli kaydı — asla silinmez
-- (mevcut "adli kayıt politikası" ile aynı ruh: bir pusu/teslimatın
-- gerçekten olup olmadığı sonradan denetlenebilir kalır).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_rendezvous_events` (
    `id`               INT          NOT NULL AUTO_INCREMENT,
    `citizenid`        VARCHAR(50)  NOT NULL,
    `catalog_type`     ENUM('weapon','ammo') NOT NULL,
    `catalog_id`       VARCHAR(64)  NOT NULL,
    `handoff_x`        FLOAT        NOT NULL DEFAULT 0.0,
    `handoff_y`        FLOAT        NOT NULL DEFAULT 0.0,
    `handoff_z`        FLOAT        NOT NULL DEFAULT 0.0,
    `trace_level_at_handoff` FLOAT  NOT NULL DEFAULT 0.0,
    `ambush_triggered` TINYINT(1)   NOT NULL DEFAULT 0,
    `outcome`          ENUM('pending','delivered','expired') NOT NULL DEFAULT 'pending',
    `created_at`       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `resolved_at`      DATETIME     NULL,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_rendezvous_events_citizenid` (`citizenid`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- [K6-3] Paketleme Odası çalışma durumu — trap house başına TEK kayıt.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_packaging_room_state` (
    `trap_house_id` INT      NOT NULL,
    `active`        TINYINT(1) NOT NULL DEFAULT 0,
    `started_by_citizenid` VARCHAR(50) NULL,
    `updated_at`    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`trap_house_id`),
    CONSTRAINT `fk_matrix_packaging_room_state_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


SET FOREIGN_KEY_CHECKS = 1;


-- =====================================================================
-- DOĞRULAMA SORGUSU (opsiyonel — bu dosya çalıştırıldıktan sonra 3 dönmeli)
-- =====================================================================
-- SELECT COUNT(*) AS layer6_table_count
-- FROM information_schema.tables
-- WHERE table_schema = DATABASE()
--   AND table_name IN (
--       'matrix_door_reinforcement',
--       'matrix_rendezvous_events',
--       'matrix_packaging_room_state'
--   );


-- =====================================================================
-- BAKIM: Yalnızca bu migrasyonun eklediği 3 tabloyu geri almak isterseniz
-- (matrix.sql/layer5_ultimate.sql'e DOKUNMAZ). Yorumdan çıkarıp çalıştırın.
-- =====================================================================
-- SET FOREIGN_KEY_CHECKS = 0;
-- DROP TABLE IF EXISTS `matrix_packaging_room_state`;
-- DROP TABLE IF EXISTS `matrix_rendezvous_events`;
-- DROP TABLE IF EXISTS `matrix_door_reinforcement`;
-- SET FOREIGN_KEY_CHECKS = 1;


-- =======================================================================
-- ★ KAYNAK: sql/layer7_faz1.sql (orijinal icerik, birebir asagida, hicbir satir atlanmadi)
-- =======================================================================

-- =====================================================================
-- KATMAN 7 [T4] FAZ 1: OTONOM DEPO LOJISTIGI VE BURO KILIDI
-- Additive migration. Yukaridaki (matrix.sql / layer5_ultimate.sql /
-- layer6_trap_house.sql) hicbir tablosu/alani DEGISTIRILMEDI -- her
-- ifade IF NOT EXISTS ile guvenlidir.
--
-- ★ KAPSAM NOTU: 'matrix_trap_stash' burada BULUNMUYOR -- trap house'un
-- ortak deposu zaten server/logistics.lua ve server/main.lua'nin
-- matrix_trap_stash_<id> ox_inventory stash'i (RegisterStash/AddItem/
-- RemoveItem) olarak MEVCUT. Ikinci bir SQL tablosu acmak veri
-- tutarsizligina yol acardi.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Kalici Kolektif Ogrenme Hafizasi -- trap house basina, RAID'LERDE
-- SIFIRLANMAYAN, birikimli telsiz ihlali + ele gecirilen urun saflik
-- kaydi. server/bureau.lua [T4] blogunun Buro Kilidi (lockdown_active)
-- karari BU tablodan turer; matrix_bureau_intel (mevcut) ile KARISTIRILMAZ
-- -- o yalnizca heat/triangulation/pattern yogunlugu tasir.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_bureau_learning_core` (
    `id`                          INT      NOT NULL AUTO_INCREMENT,
    `trap_house_id`               INT      NOT NULL,
    `frequent_zones`              TEXT     NULL COMMENT 'JSON array: bu trap house icin tekrarlanan ihlal etiketleri',
    `radio_breach_count`          INT      NOT NULL DEFAULT 0,
    `average_purity_intercepted`  FLOAT    NOT NULL DEFAULT 0.0 COMMENT '[0,1] olcek, matrix_kitchen_batches.output_purity ile ayni',
    `purity_sample_count`         INT      NOT NULL DEFAULT 0 COMMENT 'average_purity_intercepted hareketli ortalamasinin kendi bagimsiz sayaci',
    `lockdown_active`             TINYINT(1) NOT NULL DEFAULT 0,
    `updated_at`                  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_matrix_learning_core_trap_house` (`trap_house_id`),
    CONSTRAINT `fk_matrix_learning_core_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- ---------------------------------------------------------------------
-- Toplu Satis Hub'lari (District Distribution Hubs) -- F10 ile kritik
-- kavsaklara atanan, trap house'un ortak deposundan (matrix_trap_stash_
-- <id>) sabit miktarli/RNG'siz toplu satis dongusu yuruten dugumler.
-- `locked`, server/bureau.lua [T4]'un 'matrix:internal:bureauLockdown'
-- yayinindan senkronize edilir (server/district_hubs.lua).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_district_hubs` (
    `id`             INT          NOT NULL AUTO_INCREMENT,
    `trap_house_id`  INT          NOT NULL,
    `label`          VARCHAR(100) NOT NULL,
    `coord_x`        FLOAT        NOT NULL,
    `coord_y`        FLOAT        NOT NULL,
    `coord_z`        FLOAT        NOT NULL,
    `active`         TINYINT(1)   NOT NULL DEFAULT 1,
    `locked`         TINYINT(1)   NOT NULL DEFAULT 0,
    `created_at`     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_district_hubs_trap_house` (`trap_house_id`),
    CONSTRAINT `fk_matrix_district_hubs_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- =======================================================================
-- ★ KAYNAK: sql/layer7_faz3.sql (orijinal icerik, birebir asagida, hicbir satir atlanmadi)
-- =======================================================================

-- =====================================================================
-- KATMAN 7 [T4] FAZ 3: OX_TARGET SOKAK DEVSIRME KOPRUSU
-- Additive migration. Yukaridaki (matrix.sql / layer5_ultimate.sql /
-- layer6_trap_house.sql / layer7_faz1.sql) hicbir tablosu/alani
-- DEGISTIRILMEDI -- ayni disiplin, yeni bir ALTER TABLE.
--
-- loyalty_base: [0,1] olcek, diger psychology alanlari (resilience,
-- snitch_tendency, ...) ILE AYNI sekilde matrix_bots'a eklenir.
-- server/recruitment.lua Matrix.Recruitment.RecruitStreetNpc'nin
-- ustunde calistigi TEK psikoloji semasi budur -- ikinci bir tablo
-- ACILMAZ. Varsayilan 0.5 (mevcut resilience/cognitive_shifter
-- varsayilanlariyla AYNI taban); yalnizca Ox_Target "Kadroya Kat"
-- devsirmesi (server/market.lua, /sokakdevsir test komutu ile AYNI
-- disiplin) bunu acikca 1.0 (mutlak sadik) yazar.
--
-- NOT: `ADD COLUMN IF NOT EXISTS`, MySQL 8.0.29+ / MariaDB 10.0+
-- gerektirir (oxmysql'in desteklediği surumlerin tamami bunu karsilar).
-- =====================================================================
ALTER TABLE `matrix_bots`
    ADD COLUMN IF NOT EXISTS `loyalty_base` FLOAT NOT NULL DEFAULT 0.5
        COMMENT '[0,1]; Ox_Target ile devsirilen ajanlar 1.0 (mutlak sadik) alir'
        AFTER `snitch_tendency`;


-- =======================================================================
-- ★ KAYNAK: sql/matrix_security_hardening.sql (orijinal icerik, birebir asagida, hicbir satir atlanmadi)
-- =======================================================================

-- =====================================================================
-- MATRIX SECURITY HARDENING PATCH / sql/matrix_security_hardening.sql
--
-- Bu migration, server/blackmarket.lua + server/bureau.lua ADLİ GÜVENLİK
-- DENETİMİ (7 maddelik zafiyet raporu) sonucu eklenen TEK yeni tabloyu
-- taşır: [SEC-2] "Hard Drop-Out / Orphan State" düzeltmesinin son çare
-- (son-kertede) tahsilat defteri.
--
-- matrix.sql'in KENDİSİ değiştirilmedi (mevcut şemaya elle dokunmak
-- riskli) -- bu proje layer5_ultimate.sql / layer6_trap_house.sql /
-- layer7_faz1.sql / layer7_faz3.sql ile AYNI "ek (additive) migration"
-- disiplinini izler. matrix.sql'den (veya son layer dosyasından) SONRA,
-- FOREIGN_KEY_CHECKS zaten 1'e dönmüş haldeyken import edilmelidir.
--
-- NOT: bu dosya "layer8" olarak ADLANDIRILMADI -- matrix.sql'in kendi
-- yorumunda KATMAN 8 zaten "Hard-Wipe / E_total" adlı, henüz tanımsız ve
-- BİLİNÇLİ OLARAK ertelenmiş ayrı bir özelliğe ayrılmış. Bu dosya o
-- katmanla KARIŞTIRILMASIN diye bağımsız bir isim taşır.
-- =====================================================================


-- ---------------------------------------------------------------------
-- ★ [SEC-2] Offline İade Son Çare Defteri
--
-- RefundCash (server/blackmarket.lua) şu sırayla dener:
--   1) Oyuncu çevrimiçiyse: Matrix.QBX Functions.AddMoney (anında).
--   2) Değilse: players.money JSON_SET ile ACID tek-UPDATE offline iade.
--   3) O UPDATE 0 satır etkilerse (citizenid players'ta yok -- silinmiş/
--      tanınmayan karakter): bu tabloya yazılır. Para HİÇBİR KOŞULDA
--      sessizce kaybolmaz; bir admin bu tabloyu görüp manuel mutabakat
--      yapabilir. Asla otomatik silinmez/işlenmez (yalnızca INSERT).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_pending_refunds` (
    `id`          INT          NOT NULL AUTO_INCREMENT,
    `citizenid`   VARCHAR(50)  NOT NULL,
    `amount`      DECIMAL(12,2) NOT NULL,
    `reason`      VARCHAR(100) NOT NULL,
    `resolved`    TINYINT(1)   NOT NULL DEFAULT 0,
    `resolved_by` VARCHAR(50)  DEFAULT NULL,
    `resolved_at` DATETIME     DEFAULT NULL,
    `created_at`  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_pending_refunds_citizenid` (`citizenid`),
    KEY `idx_matrix_pending_refunds_resolved` (`resolved`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- =======================================================================
-- ★ KAYNAK: sql/matrix_cctv_network.sql (orijinal icerik, birebir asagida, hicbir satir atlanmadi)
-- =======================================================================

-- =====================================================================
-- MATRIX CCTV NETWORK PATCH / sql/matrix_cctv_network.sql
--
-- Bu migration, server/forensics.lua ★ [OPSEC FAZ 1 EK] FİZİKSEL VE SİBER
-- DELİL İMHA MEKANİZMASI (Matrix.Forensics.HackCCTVNetwork) için TEK yeni
-- tabloyu taşır. matrix.sql'in (veya son layer/hardening dosyasının)
-- KENDİSİ değiştirilmedi -- bu proje layer5_ultimate.sql / layer6_trap_
-- house.sql / layer7_faz1.sql / layer7_faz3.sql / matrix_security_
-- hardening.sql İLE AYNI "ek (additive) migration" disiplinini izler.
-- matrix.sql'den (veya son migration dosyasından) SONRA, FOREIGN_KEY_CHECKS
-- zaten 1'e dönmüş haldeyken import edilmelidir.
--
-- ★ KAPSAM NOTU: bu migration YALNIZCA HackCCTVNetwork'ün SİLDİĞİ tabloyu
-- tanımlar. Mobese ağının oyuncu/bot kıyafet eşleşmesini GERÇEKTEN nasıl
-- TESPİT EDİP bu tabloya YAZACAĞI (bir algılama/computer-vision motoru)
-- bu görevin kapsamı DIŞINDADIR -- Config.AI_Matrix_Brain'in "altyapı
-- hazır, motor gelecekte devreye girer" (enabled=false) köprüsüyle AYNI
-- bilinçli erteleme. server/forensics.lua'daki /cctvkaydet test komutu,
-- gerçek bir algılama motoru olmadan bu tabloyu manuel doldurmak için
-- (bkz. server/bureau.lua /dropsizintiekle İLE AYNI "test-veri-ekleme"
-- disiplini) eklendi.
-- =====================================================================


-- ---------------------------------------------------------------------
-- Mobese Dağıtım Kutusu Kayıtları — bölge başına, zaman damgalı kıyafet/
-- maskeleme eşleşme günlüğü. HackCCTVNetwork yalnızca `masked = 0`
-- (maskesiz/şüpheli) VE son 30 dakika içindeki satırları siler; maskeli
-- (masked = 1) satırlar veya 30 dakikadan eski satırlar HİÇ ETKİLENMEZ.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_cctv_logs` (
    `id`           INT          NOT NULL AUTO_INCREMENT,
    `zone_id`      INT          NOT NULL,
    `dna_id`       VARCHAR(64)  NOT NULL,
    `masked`       TINYINT(1)   NOT NULL DEFAULT 0,
    `clothing_tag` VARCHAR(64)  NOT NULL DEFAULT 'unknown',
    `created_at`   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_cctv_logs_zone_time` (`zone_id`, `created_at`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- =====================================================================
-- DOĞRULAMA SORGUSU (opsiyonel — bu dosya çalıştırıldıktan sonra 1 dönmeli)
-- =====================================================================
-- SELECT COUNT(*) AS matrix_cctv_network_table_count
-- FROM information_schema.tables
-- WHERE table_schema = DATABASE()
--   AND table_name IN ('matrix_cctv_logs');


-- =====================================================================
-- BAKIM: Yalnızca bu migrasyonun eklediği tabloyu geri almak isterseniz.
-- Yorumdan çıkarıp çalıştırın.
-- =====================================================================
-- DROP TABLE IF EXISTS `matrix_cctv_logs`;


-- =======================================================================
-- ★ KAYNAK: sql/layer_regression_schema.sql (bu oturumda eklendi, birebir asagida)
-- =======================================================================

-- =====================================================================
-- ★★★ REGRESYON: 9 DB ŞEMA KONTROLÜ + ADLİ RPG / KOR NOKTA ŞEMASI ★★★
-- matrix_diagnostics.lua DbChecks tablosuna geri enjekte edilen 9 kontrolün
-- dayandığı şema + /davaac (Adli RPG), FragmentTerritory (Gang Learning
-- Core) ve /telefonuyoket (Adli Sabotaj) için gereken YENİ tablolar/kolonlar.
-- Bu dosya defalarca çalıştırılabilir (IF NOT EXISTS / kolon varlık
-- kontrolü olmayan ALTER'lar için, MySQL 8+ üzerinde ADD COLUMN IF NOT
-- EXISTS kullanılır; eski MySQL 5.7 için elle bir kez uygulayın).
-- =====================================================================

-- [1] matrix_zone_ledger.dirty_cash_pool -- bölgeye bağlı, henüz aklanmamış
-- kirli nakit havuzu (Matrix.CashDecay ile AYNI "kirli nakit" kavramı,
-- yalnızca bölge bazında ayrı bir toplam).
ALTER TABLE `matrix_zone_ledger`
    ADD COLUMN IF NOT EXISTS `dirty_cash_pool` FLOAT NOT NULL DEFAULT 0.0;

-- [2] matrix_bots.accounting_precision -- botun kendi nakit/envanter
-- muhasebesinin (BotStreetCash vb.) ne kadar "temiz" tutulduğunu ölçen,
-- [0,1] ölçekli bir sağlık katsayısı.
ALTER TABLE `matrix_bots`
    ADD COLUMN IF NOT EXISTS `accounting_precision` FLOAT NOT NULL DEFAULT 1.0;

-- [KOR NOKTA] matrix_bots.handler_citizenid + genişletilmiş status ENUM'u
-- (server/bureau.lua Matrix.Bureau.ExecuteVerdict bulk-disband hedeflemesi
-- + Koma Modu için).
ALTER TABLE `matrix_bots`
    ADD COLUMN IF NOT EXISTS `handler_citizenid` VARCHAR(50) NULL;
ALTER TABLE `matrix_bots`
    MODIFY COLUMN `status` ENUM('active','burned','deceased','retired','disbanded','comatose') NOT NULL DEFAULT 'active';

-- [3] matrix_zone_inspectors.is_wiped -- bir Denetleyici'nin istihbaratı
-- (kendi kayıtları) bir /kameralogutemizle veya /telefonuyoket sabotajıyla
-- kazınmışsa işaretlenir.
ALTER TABLE `matrix_zone_inspectors`
    ADD COLUMN IF NOT EXISTS `is_wiped` TINYINT(1) NOT NULL DEFAULT 0;

-- [4] matrix_purchase_logs -- Büro'nun saatlik mali denetiminin (bkz.
-- server/bureau.lua Matrix.Bureau.RunHourlyFinancialAudit) 24 saatten eski
-- satırları otonom budadığı genel fatura/işlem günlüğü.
CREATE TABLE IF NOT EXISTS `matrix_purchase_logs` (
    `id`          INT          NOT NULL AUTO_INCREMENT,
    `citizenid`   VARCHAR(50)  NULL,
    `item_ref`    VARCHAR(100) NOT NULL,
    `amount`      FLOAT        NOT NULL DEFAULT 0.0,
    `created_at`  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_purchase_logs_created_at` (`created_at`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- [5] matrix_customer_pool.is_dead -- bir sokak müşterisinin (keş) kalıcı
-- olarak havuzdan düşmesi gerektiğini işaretler (aşırı doz/koma zinciriyle
-- AYNI felsefe, bkz. Koma Modu).
ALTER TABLE `matrix_customer_pool`
    ADD COLUMN IF NOT EXISTS `is_dead` TINYINT(1) NOT NULL DEFAULT 0;

-- [6] matrix_gang_learning_core -- FragmentTerritory (server/district_hubs.lua)
-- her bölünmede bir satır işler: hangi trap house'un cete lideri düştü,
-- kaç Alt Hücre'ye (Splinter Cell) bölündü.
CREATE TABLE IF NOT EXISTS `matrix_gang_learning_core` (
    `id`               INT      NOT NULL AUTO_INCREMENT,
    `trap_house_id`    INT      NOT NULL,
    `splinter_count`   INT      NOT NULL DEFAULT 0,
    `aggression_level` FLOAT    NOT NULL DEFAULT 0.0,
    `updated_at`       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_gang_learning_core_trap_house` (`trap_house_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- [7] matrix_trial_records -- /davaac + /davasorgula (server/bureau.lua)
-- çift fazlı adli RPG diyalog zincirinin kalıcı dava dosyası.
CREATE TABLE IF NOT EXISTS `matrix_trial_records` (
    `id`                   INT          NOT NULL AUTO_INCREMENT,
    `defendant_citizenid`  VARCHAR(50)  NOT NULL,
    `dna_id`               VARCHAR(64)  NOT NULL,
    `ballistic_id`         VARCHAR(64)  NULL,
    `match_certainty`      FLOAT        NOT NULL DEFAULT 0.0,
    `lie_count`            INT          NOT NULL DEFAULT 0,
    `conviction_weight`    FLOAT        NOT NULL DEFAULT 0.0,
    `verdict`              VARCHAR(20)  NOT NULL DEFAULT 'pending',
    `opened_at`            DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `closed_at`            DATETIME     NULL,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_trial_records_defendant` (`defendant_citizenid`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- [8] matrix_player_state.imprisoned -- /davaac verdict %100 mahkumiyette
-- karakter kilidi (Karakter Wipe + DropPlayer).
ALTER TABLE `matrix_player_state`
    ADD COLUMN IF NOT EXISTS `imprisoned` TINYINT(1) NOT NULL DEFAULT 0;

-- [9] matrix_legal_plate_evidence -- plaka-bazlı adli delil izi (matrix_fleet
-- ile AYNI plaka kimlik uzayı; ikinci bir "plaka" kavramı İCAT EDİLMEZ).
CREATE TABLE IF NOT EXISTS `matrix_legal_plate_evidence` (
    `id`            INT          NOT NULL AUTO_INCREMENT,
    `plate`         VARCHAR(32)  NOT NULL,
    `citizenid`     VARCHAR(50)  NULL,
    `ballistic_id`  VARCHAR(64)  NULL,
    `recorded_at`   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_legal_plate_evidence_plate` (`plate`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- [KOR NOKTA] /telefonuyoket adli sabotaj komutunun sildiği kriptolu mesaj
-- günlüğü (YENİ tablo -- matrix_forensic_evidence'ın evidence_type='cyber'
-- satırlarıyla BİRLİKTE, aynı atomik transaction'da silinir).
CREATE TABLE IF NOT EXISTS `matrix_encrypted_messages` (
    `id`           INT          NOT NULL AUTO_INCREMENT,
    `dna_id`       VARCHAR(64)  NOT NULL,
    `content_hash` VARCHAR(64)  NOT NULL,
    `created_at`   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_encrypted_messages_dna_id` (`dna_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- =======================================================================
-- ★ KAYNAK: sql/layer_splinter_cells.sql (bu oturumda eklendi, birebir asagida)
-- =======================================================================

-- =====================================================================
-- ★★★ OTONOM ALT HÜCRE BÖLÜNMESİ (FragmentTerritory / Splinter Cells) ★★★
-- Bir otonom çete lideri (bot.role == 'Leader') 'deceased' durumuna
-- düştüğünde (bkz. server/main.lua Matrix.RemoveBot), o trap house'a bağlı
-- TÜM matrix_district_hubs kayıtları bu tabloya "parçalanır" -- yeni bir
-- paralel ekonomi İCAT EDİLMEZ, yalnızca server/district_hubs.lua'nın
-- ZATEN VAR OLAN ProcessHubDemandCycle'ı + server/rendezvous.lua'nın
-- ZATEN VAR OLAN pusu event'i (matrix:client:rendezvous:triggerAmbush) +
-- server/bureau.lua'nın ZATEN VAR OLAN Matrix.Bureau.TriggerPropaganda
-- (siber-sızıntı) formülü bu yeni düğümlere BAĞLANIR.
-- =====================================================================
CREATE TABLE IF NOT EXISTS `matrix_splinter_cells` (
    `id`               INT          NOT NULL AUTO_INCREMENT,
    `parent_hub_id`    INT          NULL,
    `trap_house_id`    INT          NOT NULL,
    `splinter_index`   INT          NOT NULL,
    `coord_x`          FLOAT        NOT NULL,
    `coord_y`          FLOAT        NOT NULL,
    `coord_z`          FLOAT        NOT NULL,
    `active`           TINYINT(1)   NOT NULL DEFAULT 1,
    `created_at`       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_splinter_cells_trap_house` (`trap_house_id`),
    CONSTRAINT `fk_matrix_splinter_cells_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- =======================================================================
-- ★ KAYNAK: sql/layer_underworld_expansion.sql (bu oturumda eklendi, birebir asagida)
-- =======================================================================

-- =====================================================================
-- ★★★ YERALTI FİZİKSEL SAVAŞ + KARA TIP + SIZDIRILAN İSTİHBARAT
-- GENİŞLEMESİ (7 katmanlı görev seti) ★★★
-- Additive migration -- yukaridaki hicbir tablo/kolon DEGISTIRILMEZ.
-- =====================================================================


-- ---------------------------------------------------------------------
-- [KATMAN 2] Legal Hospital / EMS Sizinti Döngüsü — matrix_player_state'e
-- yara/balistik imza kolonlari.
-- ---------------------------------------------------------------------
ALTER TABLE `matrix_player_state`
    ADD COLUMN IF NOT EXISTS `has_wound` TINYINT(1) NOT NULL DEFAULT 0;
ALTER TABLE `matrix_player_state`
    ADD COLUMN IF NOT EXISTS `wound_ballistic_id` VARCHAR(64) NULL;


-- ---------------------------------------------------------------------
-- [KATMAN 3/4] Arma-tarzi Bölgesel Bot Yaralanma/Etkisizleştirme +
-- Kalıcı Uzuv Sakatlığı. Koma modu (status='comatose', ZATEN VAR OLAN
-- withdrawal_index tetiği, bkz. server/bureau.lua) DEĞİŞTİRİLMEZ.
-- ---------------------------------------------------------------------
ALTER TABLE `matrix_bots`
    ADD COLUMN IF NOT EXISTS `wound_zone` VARCHAR(16) NULL;
ALTER TABLE `matrix_bots`
    ADD COLUMN IF NOT EXISTS `leg_injury` FLOAT NOT NULL DEFAULT 0.0;
ALTER TABLE `matrix_bots`
    ADD COLUMN IF NOT EXISTS `head_injury` FLOAT NOT NULL DEFAULT 0.0;
ALTER TABLE `matrix_bots`
    ADD COLUMN IF NOT EXISTS `arm_injury` FLOAT NOT NULL DEFAULT 0.0;
ALTER TABLE `matrix_bots`
    ADD COLUMN IF NOT EXISTS `permanently_crippled` TINYINT(1) NOT NULL DEFAULT 0;
ALTER TABLE `matrix_bots`
    ADD COLUMN IF NOT EXISTS `installed_prosthetic` TINYINT(1) NOT NULL DEFAULT 0;
-- Karaborsa Ameliyati / Trap House tedavisi kilit sayaci (12s tedavi /
-- 24s Hayalet Cerrah ameliyati bu tek kolonu paylasir -- ayni "kilitli
-- zaman damgasi" deseni ComaClock ILE AYNI felsefe, RAM yerine kalici).
ALTER TABLE `matrix_bots`
    ADD COLUMN IF NOT EXISTS `medical_lock_until` DATETIME NULL;


-- ---------------------------------------------------------------------
-- [KATMAN 3] Bölge kitapları (matrix_zone_ledger, ZATEN VAR OLAN) için
-- denetim-uyarısı anomali oranı -- gövde yarası + Büro sting'i buraya
-- yazar.
-- ---------------------------------------------------------------------
ALTER TABLE `matrix_zone_ledger`
    ADD COLUMN IF NOT EXISTS `audit_anomaly_rate` FLOAT NOT NULL DEFAULT 0.0;


-- ---------------------------------------------------------------------
-- [KATMAN 5] Deterministik Taze-Kurulum Satıcı Dağılımı — sunucu ilk
-- açılışta, server/DB adı + satıcı id'sinin sağlama toplamından türetilir
-- (RNG YOK, bkz. server/underworld_network.lua ChecksumOf).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_vendor_pool` (
    `id`               INT          NOT NULL AUTO_INCREMENT,
    `vendor_citizenid` VARCHAR(50)  NULL,
    `coord_x`          FLOAT        NOT NULL,
    `coord_y`          FLOAT        NOT NULL,
    `coord_z`          FLOAT        NOT NULL,
    `gang_loyalty`     FLOAT        NOT NULL DEFAULT 0.5,
    `fear_index`       FLOAT        NOT NULL DEFAULT 0.3,
    `status`           VARCHAR(32)  NOT NULL DEFAULT 'active',
    PRIMARY KEY (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;
-- Satici tekilligi/istismar izi -- sabotajli silahlarin (jam_accumulator
-- onceden yuksek) hangi saticidan gectigini kaydeder; ikinci bir tablo
-- ACILMAZ, tek bayrak kolonu yeterlidir.
ALTER TABLE `matrix_vendor_pool`
    ADD COLUMN IF NOT EXISTS `compromised` TINYINT(1) NOT NULL DEFAULT 0;


-- ---------------------------------------------------------------------
-- [KATMAN 6] Parçalanmış İstihbarat Defteri + Karşı-İstihbarat Vetting.
-- contact_ref: hangi somut satici/doktor kaydina (matrix_vendor_pool.id
-- veya 'phantom_doctor') ait oldugunu belirtir -- literal spesifikasyon
-- semasi (citizenid/contact_type/intel_fragments) KORUNUR, yalnizca
-- discovered/compromised/contact_ref ADDITIVE olarak eklenir.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_fragmented_intel` (
    `id`              INT          NOT NULL AUTO_INCREMENT,
    `citizenid`       VARCHAR(50)  NOT NULL,
    `contact_type`    VARCHAR(50)  NOT NULL,
    `intel_fragments` FLOAT        DEFAULT 0.0,
    PRIMARY KEY (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;
ALTER TABLE `matrix_fragmented_intel`
    ADD COLUMN IF NOT EXISTS `contact_ref` VARCHAR(64) NULL;
ALTER TABLE `matrix_fragmented_intel`
    ADD COLUMN IF NOT EXISTS `discovered` TINYINT(1) NOT NULL DEFAULT 0;
ALTER TABLE `matrix_fragmented_intel`
    ADD COLUMN IF NOT EXISTS `compromised` TINYINT(1) NOT NULL DEFAULT 0;
ALTER TABLE `matrix_fragmented_intel`
    ADD COLUMN IF NOT EXISTS `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP;


-- ---------------------------------------------------------------------
-- [KATMAN 7] Düşman Çete Mahalleleri + Sıfır-Toplam Yağma Motoru +
-- Balistik Suç Yükleme (Frame-Up). stash_id: matrix_trap_stash_<id> ILE
-- AYNI ox_inventory RegisterStash disiplini -- ikinci bir kalicilik
-- kaynagi ACILMAZ.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_gang_hoods` (
    `id`           INT          NOT NULL AUTO_INCREMENT,
    `hood_label`   VARCHAR(100) NOT NULL,
    `control_ratio` FLOAT       NOT NULL DEFAULT 1.0,
    `stash_id`     VARCHAR(64)  NULL,
    PRIMARY KEY (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;
ALTER TABLE `matrix_gang_hoods`
    ADD COLUMN IF NOT EXISTS `coord_x` FLOAT NOT NULL DEFAULT 0.0;
ALTER TABLE `matrix_gang_hoods`
    ADD COLUMN IF NOT EXISTS `coord_y` FLOAT NOT NULL DEFAULT 0.0;
ALTER TABLE `matrix_gang_hoods`
    ADD COLUMN IF NOT EXISTS `coord_z` FLOAT NOT NULL DEFAULT 0.0;
ALTER TABLE `matrix_gang_hoods`
    ADD COLUMN IF NOT EXISTS `nearest_trap_house_id` INT NULL;
ALTER TABLE `matrix_gang_hoods`
    ADD COLUMN IF NOT EXISTS `loot_opened_at` DATETIME NULL;
ALTER TABLE `matrix_gang_hoods`
    ADD COLUMN IF NOT EXISTS `loot_compound_ticks` INT NOT NULL DEFAULT 0;


-- =====================================================================
-- ★ KATMAN 21: ACIMASIZ DIAGNOSTICS LABORATUVARI -- 100 eszamanli async
-- satis stres testinin (server/matrix_diagnostics.lua RunConcurrencyStressCheck)
-- yazdigi kayitlar icin, CANLI ekonomi tablolarindan TAMAMEN izole,
-- tani-yalnizca bir gunluk. Her calistirmadan sonra run_token'a gore
-- silinir -- kalici veri BIRIKTIRMEZ.
-- =====================================================================
CREATE TABLE IF NOT EXISTS `matrix_diagnostics_stress_log` (
    `id`           INT AUTO_INCREMENT,
    `run_token`    VARCHAR(64) NOT NULL,
    `worker_index` INT         NOT NULL,
    `removed_ok`   TINYINT     NOT NULL DEFAULT 0,
    `created_at`   DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_run_token` (`run_token`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- =====================================================================
-- DOĞRULAMA SORGUSU (opsiyonel — bu dosya çalıştırıldıktan sonra 4 dönmeli)
-- =====================================================================
-- SELECT COUNT(*) AS underworld_expansion_table_count
-- FROM information_schema.tables
-- WHERE table_schema = DATABASE()
--   AND table_name IN (
--       'matrix_vendor_pool',
--       'matrix_fragmented_intel',
--       'matrix_gang_hoods',
--       'matrix_diagnostics_stress_log'
--   );
-- =====================================================================
-- ★ KATMAN 23: DIAGNOSTICS BEKÇİLERİ — EKSİK KOLONLAR ★
-- =====================================================================
SET FOREIGN_KEY_CHECKS = 0;

ALTER TABLE `matrix_vendor_pool`
    ADD COLUMN IF NOT EXISTS `vendor_license` VARCHAR(64) NULL;

ALTER TABLE `matrix_player_state`
    ADD COLUMN IF NOT EXISTS `recovery_target_epoch` BIGINT NULL;

ALTER TABLE `matrix_forensic_evidence`
    ADD COLUMN IF NOT EXISTS `evidence_tampering` TINYINT(1) NOT NULL DEFAULT 0;

ALTER TABLE `matrix_forensic_evidence`
    ADD COLUMN IF NOT EXISTS `biological_trauma` TINYINT(1) NOT NULL DEFAULT 0;

ALTER TABLE `matrix_forensic_evidence`
    ADD COLUMN IF NOT EXISTS `inflicted_force_striation` FLOAT NOT NULL DEFAULT 0.0;

SET FOREIGN_KEY_CHECKS = 1;

-- =======================================================================
-- ★ KAYNAK: sql/layer8_milsim_expansion.sql (bu oturumda birlestirildi)
-- =======================================================================
-- ★★★ KATMAN 8: LİMAN KAÇAKÇILIK + KRİPTO CÜZDAN AĞLARI ★★★
-- Additive-only. Yukaridaki hicbir tablo/kolon DEGISTIRILMEZ.
-- =======================================================================

SET FOREIGN_KEY_CHECKS = 0;

-- ---------------------------------------------------------------------
-- [CEPHE A] Liman Gumruk Check-in Gunlugu -- bot rampa bolgesine
-- girdiginde matrix_bureau_intensity ConVar'ının x2 katlanmasını ve
-- client-relay driveby isteginin kanıt kaydını tutar.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_port_smuggling_events` (
    `id`               INT          NOT NULL AUTO_INCREMENT,
    `bot_id`           INT          NOT NULL,
    `port_zone`        VARCHAR(32)  NOT NULL DEFAULT 'port_ramp',
    `intensity_before` FLOAT        NOT NULL DEFAULT 1.0,
    `intensity_after`  FLOAT        NOT NULL DEFAULT 1.0,
    `dispatch_plate`   VARCHAR(32)  NULL,
    `driveby_pushed`   TINYINT(1)   NOT NULL DEFAULT 0,
    `created_at`       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_port_smuggling_bot` (`bot_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- ---------------------------------------------------------------------
-- [CEPHE B] Anonim Kripto Cuzdan Agi -- SEC-6 rolling cipher mutasyon
-- protokolu. wallet_address SHA-256 benzeri 64-karakter hex (0x onekli).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_crypto_wallets` (
    `wallet_address`     VARCHAR(64)  NOT NULL,
    `holder_identifier`  VARCHAR(50)  NOT NULL,
    `holder_type`        ENUM('player','bot') NOT NULL DEFAULT 'player',
    `crypto_balance`     DECIMAL(16,4) NOT NULL DEFAULT 0.0000,
    `rolling_cipher_key` VARCHAR(64)  NOT NULL,
    `tx_sequence`        INT          NOT NULL DEFAULT 0,
    `created_at`         DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at`         DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`wallet_address`),
    KEY `idx_matrix_crypto_wallets_holder` (`holder_type`, `holder_identifier`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

SET FOREIGN_KEY_CHECKS = 1;


-- =======================================================================
-- ★ KAYNAK: sql/layer_23_diagnostics_bekcileri.sql (bu oturumda birlestirildi)
-- =======================================================================
-- ★ KATMAN 23: DIAGNOSTICS BEKÇİLERİ — EKSİK KOLON MİGRASYONU ★
-- server/matrix_diagnostics.lua'nın [ADDITIVE] bekçilik kontrolleri
-- (KATMAN 5/6 GM emirleri) dayandığı kolonları ekler. Yukarıdaki hiçbir
-- tabloya/kolona DOKUNULMAZ — yalnızca ADD COLUMN IF NOT EXISTS.
-- =======================================================================

SET FOREIGN_KEY_CHECKS = 0;

-- [KATMAN 6] Satıcı lisansı — düşman finansmanlı satıcıların kimlik izi
ALTER TABLE `matrix_vendor_pool`
    ADD COLUMN IF NOT EXISTS `vendor_license` VARCHAR(64) NULL
        COMMENT 'Sahte/belgeli satici kimlik izi';

-- [KATMAN 5] 24 Saatlik Data Recovery — müsadere edilen cihazın çözülme
-- hedefi (Unix epoch, restart'ta geri sarmaz)
ALTER TABLE `matrix_player_state`
    ADD COLUMN IF NOT EXISTS `recovery_target_epoch` BIGINT NULL
        COMMENT 'Musadere edilen cihazin cozulme hedef zamani (Unix epoch)';

-- [KATMAN 4] Taktiksel Güç Uygulaması — adli kanıt zinciri bayrakları
ALTER TABLE `matrix_forensic_evidence`
    ADD COLUMN IF NOT EXISTS `evidence_tampering` TINYINT(1) NOT NULL DEFAULT 0
        COMMENT 'Kanit odasi sabotaji gordu mu (TamperEvidenceLockup)';
ALTER TABLE `matrix_forensic_evidence`
    ADD COLUMN IF NOT EXISTS `biological_trauma` TINYINT(1) NOT NULL DEFAULT 0
        COMMENT 'Biyolojik tramva kaniti mi (kontrollugucuyula)';
ALTER TABLE `matrix_forensic_evidence`
    ADD COLUMN IF NOT EXISTS `inflicted_force_striation` FLOAT NOT NULL DEFAULT 0.0
        COMMENT 'Uygulanan fiziksel gucun uzuv bazli hasar katsayisi';

-- =====================================================================
-- ★ KATMAN 8 CRITICAL: OPSEC DİNAMİK PAROLA + TAMPER LOG
-- =====================================================================
SET FOREIGN_KEY_CHECKS = 0;

-- [FAZ 1] Trap house başına oyun içi rotasyona açık parola (hash).
-- Default 'CORE_MATRIX_INIT_PASS' — ilk açılışta her trap house bu
-- passphrase ile mühürlenir, GM panelinden değiştirilebilir.
ALTER TABLE `matrix_trap_houses`
    ADD COLUMN IF NOT EXISTS `opsec_passphrase` VARCHAR(64) NOT NULL
        DEFAULT 'CORE_MATRIX_INIT_PASS'
        COMMENT 'SEC-7 dinamik parola — düz metin değil, SHA256-benzeri hex';

-- [FAZ 1] Yanlış parola → adli iz kaydı (asla silinmez, "adli kayıt
-- politikası" ruhuna uygun).
CREATE TABLE IF NOT EXISTS `matrix_opsec_tamper_log` (
    `id`                        INT          NOT NULL AUTO_INCREMENT,
    `trap_house_id`             INT          NOT NULL,
    `citizenid`                 VARCHAR(50)  NULL,
    `attempted_passphrase_hash` VARCHAR(64)  NOT NULL,
    `geometric_step`            FLOAT        NOT NULL DEFAULT 0.0,
    `decryption_after`          FLOAT        NOT NULL DEFAULT 0.0,
    `created_at`                DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_opsec_tamper_trap` (`trap_house_id`),
    KEY `idx_matrix_opsec_tamper_citizen` (`citizenid`),
    CONSTRAINT `fk_matrix_opsec_tamper_trap`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

SET FOREIGN_KEY_CHECKS = 1;

-- =======================================================================
-- ★ [FIX] PARAVAN_REAL_ESTATE_PHASE2 eksik kolonlari — server/bureau.lua
-- Matrix.Bureau.CreateTrapHouse/LoadTrapHouses/AssignStrawBuyer/
-- _HandleParavanSeizure bu iki kolonu ZATEN okuyup yaziyordu ama hicbir
-- migration dosyasi (bu dosya dahil) onlari hic eklememisti --
-- /traphouseekle calistirinca "Unknown column 'straw_buyer_citizenid'"
-- hatasiyla cökerdi. Additive, IF NOT EXISTS.
-- =======================================================================
SET FOREIGN_KEY_CHECKS = 0;

ALTER TABLE `matrix_trap_houses`
    ADD COLUMN IF NOT EXISTS `straw_buyer_citizenid` VARCHAR(50) NULL
        COMMENT 'PARAVAN_REAL_ESTATE_PHASE2: bu trap house''un tapu sahibi gorunen paravan botun handler citizenid''si',
    ADD COLUMN IF NOT EXISTS `structural_integrity` FLOAT NOT NULL DEFAULT 1.00
        COMMENT 'PARAVAN_REAL_ESTATE_PHASE2: 0.00 = el konuldu (paravan deceased/burned), 1.00 = saglam';

SET FOREIGN_KEY_CHECKS = 1;

-- =======================================================================
-- ★ [TERRITORY POACHING] server/district_hubs.lua Matrix.DistrictHubs.
-- PoachRivalTerritory tarafindan kullanilir. Rakip bir cete mahallesinin
-- (matrix_gang_hoods) control_ratio'su esigin altina dustugunde, o
-- mahalleye baglanmis musteriler paylasilan 'groove' ittifakinin en yakin
-- fonksiyonel trap house bolgesine yeniden atanir. Ayri bir tablo
-- ICAT EDILMEZ -- sadece ADD COLUMN IF NOT EXISTS.
-- =======================================================================
SET FOREIGN_KEY_CHECKS = 0;

ALTER TABLE `matrix_customer_pool`
    ADD COLUMN IF NOT EXISTS `preferred_zone` INT NULL
        COMMENT 'Musterinin tercih ettigi bolge (trap house id veya cete mahallesi id) -- FragmentTerritory/PoachRivalTerritory tarafindan yeniden atanir';

SET FOREIGN_KEY_CHECKS = 1;

-- =====================================================================
-- MATRIX PHASE 6 / STEP 3 — HYDRAULIC BRICK PRESS ADDITIVE MIGRATION
-- =====================================================================
ALTER TABLE matrix_trap_houses ADD COLUMN IF NOT EXISTS brick_press_status VARCHAR(24) DEFAULT 'idle';
ALTER TABLE matrix_trap_houses ADD COLUMN IF NOT EXISTS total_compressed_bricks INT DEFAULT 0;

-- Optional forward-compat columns for botany override (used by SetBotanyEnvironment)
ALTER TABLE matrix_botany_cabinets ADD COLUMN IF NOT EXISTS target_ph FLOAT DEFAULT 6.0;
ALTER TABLE matrix_botany_cabinets ADD COLUMN IF NOT EXISTS fan_speed FLOAT DEFAULT 2.5;


-- =======================================================================
-- BÖLÜM 2/5 — KAYNAK: sql/matrix_bot_cognition.sql (birebir)
-- =======================================================================

-- =====================================================================
-- vbs_core_matrix v3.0 PHASE 1 — COGNITIVE MATRIX ADDITIVE MIGRATION
-- Strict IF NOT EXISTS. Safe to re-run.
-- =====================================================================
CREATE TABLE IF NOT EXISTS matrix_bot_cognition (
    bot_id INT PRIMARY KEY,
    iq_score INT DEFAULT 100,
    withdrawal_index FLOAT DEFAULT 0.0,
    fatigue_accumulation FLOAT DEFAULT 0.0,
    current_drug_influence VARCHAR(32) DEFAULT 'none',
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- =======================================================================
-- BÖLÜM 3/5 — KAYNAK: sql/phase3_persistent_vehicles.sql (birebir)
-- =======================================================================

-- =====================================================================
-- MATRIX PHASE 3 — Persistent No-Cache Vehicles & Arson Forensic Ledger
-- MariaDB 10.4+ / MySQL 8.0+ uyumlu
-- Deterministik, idempotent, strict IF NOT EXISTS.
-- =====================================================================

-- ---------------------------------------------------------------------
-- [PV-1] KALICI ARAÇ MATRİSİ — NO-CACHE VEHICLES
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_persistent_vehicles` (
    `plate`            VARCHAR(12)  NOT NULL,
    `citizenid_owner`  VARCHAR(50)  NOT NULL,
    `vehicle_model`    INT          NOT NULL,
    `coord_x`          FLOAT        NOT NULL,
    `coord_y`          FLOAT        NOT NULL,
    `coord_z`          FLOAT        NOT NULL,
    `heading`          FLOAT        NOT NULL,
    `body_health`      FLOAT        NOT NULL DEFAULT 1000.0,
    `fuel_level`       FLOAT        NOT NULL DEFAULT 100.0,
    `status`           VARCHAR(20)  NOT NULL DEFAULT 'active_field'
        COMMENT 'parked_hood|active_field|destroyed',
    PRIMARY KEY (`plate`),
    INDEX `idx_status`  (`status`),
    INDEX `idx_owner`   (`citizenid_owner`),
    INDEX `idx_coords`  (`coord_x`, `coord_y`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


-- ---------------------------------------------------------------------
-- [AR-4] ARSON FORENSIC LEDGER — her kundaklama oturumu için kalıcı iz
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_arson_events` (
    `event_id`         BIGINT       NOT NULL AUTO_INCREMENT,
    `plate`            VARCHAR(12)  NOT NULL,
    `actor_citizenid`  VARCHAR(50)  NOT NULL,
    `started_at`       DATETIME     NOT NULL,
    `completed_at`     DATETIME     NULL,
    `outcome`          VARCHAR(24)  NOT NULL
        COMMENT 'sanitized|salvaged|aborted',
    `final_body_health` FLOAT       NOT NULL DEFAULT 0.0,
    `intensity_before` FLOAT        NOT NULL DEFAULT 0.0,
    `intensity_after`  FLOAT        NOT NULL DEFAULT 0.0,
    `sanitized`        TINYINT(1)   NOT NULL DEFAULT 0,
    PRIMARY KEY (`event_id`),
    INDEX `idx_plate`      (`plate`),
    INDEX `idx_actor`      (`actor_citizenid`),
    INDEX `idx_outcome`    (`outcome`),
    INDEX `idx_started_at` (`started_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


-- ---------------------------------------------------------------------
-- [SEC-2 LEDGER] ORPHAN REFUND KAYITLARI (logistics C-5 deseni)
-- Bu tablo zaten başka bir modülde oluşturulmuş olabilir; IF NOT EXISTS
-- ile idempotent bırakıldı. Kolon şeması mevcut yapıya uyarlandı.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_pending_refunds` (
    `id`           BIGINT       NOT NULL AUTO_INCREMENT,
    `citizenid`    VARCHAR(50)  NOT NULL,
    `amount`       DECIMAL(15,2) NOT NULL DEFAULT 0.00,
    `reason`       VARCHAR(120) NOT NULL,
    `created_at`   DATETIME     NOT NULL,
    PRIMARY KEY (`id`),
    INDEX `idx_citizenid` (`citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- =======================================================================
-- BÖLÜM 4/5 — KAYNAK: sql/phase4_hardcore_friction.sql (birebir)
-- =======================================================================

-- =====================================================================
-- MATRIX PHASE 4 — HARDCORE FRICTION FINALIZE
-- MariaDB 10.4+ / MySQL 8.0+ uyumlu
-- Deterministik, idempotent, strict IF NOT EXISTS.
-- =====================================================================

-- ---------------------------------------------------------------------
-- [LB-1] 24 SAATLİK BANKA ESCROW KİLİDİ
-- Aklanan nakit ANINDA clean balansa düşmez; 24 saatlik processing
-- penceresi boyunca bu tabloda bekletilir. Federal raid veya Büro
-- lockdown bu pencere içinde tetiklenirse %100 confiscate.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_banking_escrow` (
    `id`              BIGINT       NOT NULL AUTO_INCREMENT,
    `citizenid`       VARCHAR(50)  NOT NULL,
    `trap_house_id`   INT          NOT NULL,
    `amount`          FLOAT        NOT NULL,
    `deposited_epoch` BIGINT       NOT NULL,
    `release_epoch`   BIGINT       NOT NULL,
    `status`          VARCHAR(20)  NOT NULL DEFAULT 'processing'
        COMMENT 'processing|released|confiscated',
    `confiscated_by`  VARCHAR(64)  NULL,
    `created_at`      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    INDEX `idx_escrow_citizenid` (`citizenid`),
    INDEX `idx_escrow_release`   (`release_epoch`),
    INDEX `idx_escrow_status`    (`status`),
    INDEX `idx_escrow_trap`      (`trap_house_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- [LA-1] CCTV log satırları için progressive scrub skoru. 1.0'dan
-- başlar, -0.20/adım (5sn) ile sıfıra iner; sıfırlandığında satır
-- silinebilir.
-- ---------------------------------------------------------------------
ALTER TABLE `matrix_cctv_logs`
    ADD COLUMN IF NOT EXISTS `cctv_certainty` FLOAT NOT NULL DEFAULT 1.0
        COMMENT 'FAZ4 progressive scrub skoru; 0 = tam scrub';

-- ---------------------------------------------------------------------
-- [LA-2] Forensic evidence için progressive scrub bayrağı.
-- ---------------------------------------------------------------------
ALTER TABLE `matrix_forensic_evidence`
    ADD COLUMN IF NOT EXISTS `scrubbed` TINYINT(1) NOT NULL DEFAULT 0
        COMMENT 'FAZ4 progressive scrub tamamlandi mi';

-- ---------------------------------------------------------------------
-- [LB-4] Haftalık bozulma epoch damgası (KV deposu — restart-proof).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_kv` (
    `key_name`   VARCHAR(64)  NOT NULL,
    `value`      VARCHAR(255) NOT NULL,
    `updated_at` DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`key_name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- =======================================================================
-- BÖLÜM 5/5 — KAYNAK: sql/phase5_coercion_matrix.sql (birebir)
-- =======================================================================

SET FOREIGN_KEY_CHECKS = 0;

-- [1] matrix_forensic_evidence — eksik kolonları ekle
ALTER TABLE `matrix_forensic_evidence`
    ADD COLUMN IF NOT EXISTS `dna_id`          VARCHAR(64)   DEFAULT NULL,
    ADD COLUMN IF NOT EXISTS `citizenid`       VARCHAR(50)   DEFAULT NULL,
    ADD COLUMN IF NOT EXISTS `sanitized`       TINYINT(1)    NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS `crime_scene_ref` VARCHAR(255)  DEFAULT NULL;

-- [2] matrix_sales_ledger — yok ise oluştur
CREATE TABLE IF NOT EXISTS `matrix_sales_ledger` (
    `id`               BIGINT        NOT NULL AUTO_INCREMENT,
    `batch_id`         VARCHAR(64)   NOT NULL,
    `seller_citizenid` VARCHAR(50)   DEFAULT NULL,
    `buyer_citizenid`  VARCHAR(50)   NOT NULL,
    `purity`           DECIMAL(5,4)  NOT NULL DEFAULT 0.0,
    `grams`            DECIMAL(10,2) DEFAULT 0.0,
    `total_cash`       DECIMAL(15,2) DEFAULT 0.0,
    `created_at`       DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_buyer_purity` (`buyer_citizenid`, `purity`),
    KEY `idx_batch`        (`batch_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- [3] matrix_trap_house_stash — yok ise oluştur
CREATE TABLE IF NOT EXISTS `matrix_trap_house_stash` (
    `id`               BIGINT        NOT NULL AUTO_INCREMENT,
    `owner_citizenid`  VARCHAR(50)   NOT NULL,
    `trap_house_id`    INT           DEFAULT NULL,
    `weight_kg`        DECIMAL(10,3) NOT NULL DEFAULT 0.0,
    `cap_kg`           DECIMAL(10,3) NOT NULL DEFAULT 150.0,
    `updated_at`       DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_owner_stash` (`owner_citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

SET FOREIGN_KEY_CHECKS = 1;

-- =======================================================================
-- GÜVENLİK AĞI: yukarıdaki 5 bölümün TÜMÜ kendi FOREIGN_KEY_CHECKS
-- toggle'larını zaten dengeliyor (her 0 bir 1 ile kapanıyor); bu son
-- satır yalnızca bağlantının =1 durumunda bittiğini garantiler.
-- =======================================================================
SET FOREIGN_KEY_CHECKS = 1;

-- =====================================================================
-- SESSION 2 — PHYSICAL BOTANY LABORATORY MATRIX (additive)
-- =====================================================================
CREATE TABLE IF NOT EXISTS `matrix_botany_state` (
    `trap_house_id`        INT      NOT NULL,
    `growth_percent`       FLOAT    NOT NULL DEFAULT 0.0,
    `water_level`          FLOAT    NOT NULL DEFAULT 100.0,
    `leaf_decay`           FLOAT    NOT NULL DEFAULT 0.0,
    `ph_level`             FLOAT    NOT NULL DEFAULT 6.25,
    `infestation_state`    TINYINT  NOT NULL DEFAULT 0,
    `infestation_started`  BIGINT   NULL,
    `last_cycle_time`      BIGINT   NOT NULL,
    `crop_generation`      INT      NOT NULL DEFAULT 0,
    `updated_at`           DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`trap_house_id`),
    CONSTRAINT `fk_matrix_botany_state_trap`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


-- =====================================================================
-- ★★★ SESSION 3: ODOR EMISSION & VETTING STATE ★★★
-- =====================================================================
SET FOREIGN_KEY_CHECKS = 0;

CREATE TABLE IF NOT EXISTS `matrix_odor_state` (
    `trap_house_id`     INT          NOT NULL,
    `filter_durability` FLOAT        NOT NULL DEFAULT 0.0
        COMMENT 'Karbon filtre dayaniklilik bari 0..100',
    `filter_active`     TINYINT(1)   NOT NULL DEFAULT 0,
    `mask_until_epoch`  BIGINT       NULL
        COMMENT 'Maskeleme ajani penceresi (mutlak os.time); NULL=pasif',
    `last_filter_tick`  BIGINT       NOT NULL,
    `updated_at`        DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`trap_house_id`),
    CONSTRAINT `fk_matrix_odor_state_trap`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

SET FOREIGN_KEY_CHECKS = 1;
-- =====================================================================
-- ★★★ schema.sql — SESSION 4.90 UNIFIED CONSOLIDATION ★★★
-- matrix_v3_ultimate_combined.sql'in ÜZERİNE idempotent ek migration.
-- ÖNCE matrix_v3_ultimate_combined.sql import edilmiş olmalıdır.
--
-- ★ [4.90 HOTFIX] KAPSAM:
--   [1] matrix_trap_houses  -- koordinat tekilliği (çift-kayıt kilit).
--   [2] matrix_exploit_log  -- ADLI ŞABLON; Session 1 proxy dosyasındaki
--       DROP TABLE IF EXISTS riskine karşı programatik safety override.
--   [3] matrix_agent_pool   -- salt-okunur VIEW (bot kod-adı).
--   [4] matrix_pending_refunds -- TİP ÇAKIŞMASI ÇÖZÜLDÜ:
--       finansal ID'ler GLOBAL STANDART: BIGINT AUTO_INCREMENT,
--       para birimi GLOBAL STANDART: DECIMAL(15,2).
--       matrix_financial_core.sql (INT/DECIMAL(12,2)) ve
--       phase3_persistent_vehicles.sql (BIGINT/DECIMAL(15,2)) arasındaki
--       uyumsuzluk bilinçli olarak bu dosyada CONVERGENCE ALTER'larıyla
--       uzlaştırılır -- hangi dosya önce çalışırsa çalışsın sonuç aynıdır.
--   [5] matrix_player_telemetry -- EKSİK ŞEMA; player_telemetry.lua'nın
--       her 15sn'de bir yaptığı INSERT'ler "table doesn't exist" spam'iyle
--       oxmysql arka plan transaction kuyruğunu kirletiyordu. Bu tablo
--       deploy edilerek sessizleştirilir.
--
-- Idempotent (CREATE IF NOT EXISTS + information_schema convergence).
-- MariaDB 10.5+ / MySQL 8.0+ gerektirir.
-- =====================================================================

SET FOREIGN_KEY_CHECKS = 0;

-- ---------------------------------------------------------------------
-- [1] matrix_trap_houses — çift-kayıt istikrar kilidi
-- ---------------------------------------------------------------------
ALTER TABLE `matrix_trap_houses`
    ADD UNIQUE KEY IF NOT EXISTS `uq_matrix_trap_houses_coords` (`coord_x`, `coord_y`, `coord_z`);

-- ---------------------------------------------------------------------
-- [2] matrix_exploit_log — ADLI KAYIT KORUMASI
-- Kanonik şema (Session 1 proxy SQL'in `DROP TABLE IF EXISTS` bloku
-- kaldırılmadan bile DAYANIKLI: CREATE IF NOT EXISTS hiç var olan tabloyu
-- silmez; aşağıdaki convergence blok eski/eksik kolonları programatik
-- olarak TAMAMLAR).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_exploit_log` (
    `id`          BIGINT       NOT NULL AUTO_INCREMENT,
    `citizenid`   VARCHAR(50)  NULL,
    `source_id`   INT          NULL,
    `category`    VARCHAR(64)  NOT NULL,
    `detail`      VARCHAR(255) NOT NULL,
    `coords_x`    FLOAT        NULL,
    `coords_y`    FLOAT        NULL,
    `coords_z`    FLOAT        NULL,
    `created_at`  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_exploit_log_citizenid` (`citizenid`),
    KEY `idx_matrix_exploit_log_category`  (`category`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- Convergence: Session 1 proxy şemasından (attempted_size/active_count/
-- max_limit/coords_hash) miras kalan kolonları KORU, kanonik kolonları
-- EKLE (idempotent).
SET @has_src_id := (
    SELECT COUNT(*) FROM information_schema.columns
    WHERE table_schema = DATABASE()
      AND table_name = 'matrix_exploit_log'
      AND column_name = 'source_id'
);
SET @sql_add_src := IF(@has_src_id = 0,
    'ALTER TABLE `matrix_exploit_log` ADD COLUMN `source_id` INT NULL',
    'SELECT 1');
PREPARE stmt FROM @sql_add_src; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @has_cat := (
    SELECT COUNT(*) FROM information_schema.columns
    WHERE table_schema = DATABASE()
      AND table_name = 'matrix_exploit_log'
      AND column_name = 'category'
);
SET @sql_add_cat := IF(@has_cat = 0,
    'ALTER TABLE `matrix_exploit_log` ADD COLUMN `category` VARCHAR(64) NOT NULL DEFAULT ''legacy''',
    'SELECT 1');
PREPARE stmt FROM @sql_add_cat; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @has_detail := (
    SELECT COUNT(*) FROM information_schema.columns
    WHERE table_schema = DATABASE()
      AND table_name = 'matrix_exploit_log'
      AND column_name = 'detail'
);
SET @sql_add_detail := IF(@has_detail = 0,
    'ALTER TABLE `matrix_exploit_log` ADD COLUMN `detail` VARCHAR(255) NOT NULL DEFAULT ''''',
    'SELECT 1');
PREPARE stmt FROM @sql_add_detail; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @has_cx := (
    SELECT COUNT(*) FROM information_schema.columns
    WHERE table_schema = DATABASE()
      AND table_name = 'matrix_exploit_log'
      AND column_name = 'coords_x'
);
SET @sql_add_cx := IF(@has_cx = 0,
    'ALTER TABLE `matrix_exploit_log` ADD COLUMN `coords_x` FLOAT NULL, ADD COLUMN `coords_y` FLOAT NULL, ADD COLUMN `coords_z` FLOAT NULL',
    'SELECT 1');
PREPARE stmt FROM @sql_add_cx; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @has_citizen := (
    SELECT COUNT(*) FROM information_schema.columns
    WHERE table_schema = DATABASE()
      AND table_name = 'matrix_exploit_log'
      AND column_name = 'citizenid'
);
SET @sql_add_citizen := IF(@has_citizen = 0,
    'ALTER TABLE `matrix_exploit_log` ADD COLUMN `citizenid` VARCHAR(50) NULL',
    'SELECT 1');
PREPARE stmt FROM @sql_add_citizen; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- ---------------------------------------------------------------------
-- [3] matrix_agent_pool — salt-okunur formatlanmış VIEW
-- (schema.sql eski sürümü + session1_proxy sürümünün KOLON BİRLEŞİMİ;
--  CREATE OR REPLACE sayesinde hangisi önce çalışırsa çalışsın bu kazanır.)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `matrix_agent_pool` AS
SELECT
    CONCAT('AGENT_', LPAD(b.`id`, 5, '0'))          AS `agent_hash`,
    CONCAT('AGENT_', LPAD(b.`id`, 5, '0'))          AS `agent_code`,
    b.`id`                                          AS `legacy_bot_id`,
    b.`id`                                          AS `id`,
    b.`dna_id`                                      AS `dna_id`,
    b.`name`                                        AS `code_name`,
    b.`name`                                        AS `name`,
    b.`role`                                        AS `role`,
    b.`status`                                      AS `status`,
    b.`handler_citizenid`                           AS `handler_citizenid`,
    b.`loyalty_base`                                AS `loyalty_base`,
    COALESCE(c.`iq_score`, 100)                     AS `bot_iq`,
    b.`skill_chemistry`                             AS `skill_chemistry`,
    b.`skill_cyber`                                 AS `skill_cyber`,
    b.`skill_logistics`                             AS `skill_logistics`,
    COALESCE(c.`current_drug_influence`, 'none')    AS `current_drug_influence`,
    b.`fear_factor`                                 AS `fear_factor`,
    b.`resilience`                                  AS `resilience`,
    b.`snitch_tendency`                             AS `snitch_tendency`,
    b.`economic_pressure`                           AS `economic_pressure`,
    b.`cognitive_shifter`                           AS `cognitive_shifter`,
    b.`fatigue_level`                               AS `fatigue_level`,
    b.`cortisol_level`                              AS `cortisol_level`,
    b.`withdrawal_index`                            AS `withdrawal_index`,
    b.`addiction_level`                             AS `addiction_level`,
    b.`trap_house_id`                               AS `trap_house_id`,
    b.`created_at`                                  AS `created_at`,
    b.`updated_at`                                  AS `updated_at`
FROM `matrix_bots` b
LEFT JOIN `matrix_bot_cognition` c ON c.`bot_id` = b.`id`;

-- ---------------------------------------------------------------------
-- [4] matrix_pending_refunds — TİP ÇAKIŞMASI ÇÖZÜMÜ
-- KANONİK: BIGINT AUTO_INCREMENT + DECIMAL(15,2) + çözüm-takip alanları.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_pending_refunds` (
    `id`          BIGINT        NOT NULL AUTO_INCREMENT,
    `citizenid`   VARCHAR(50)   NOT NULL,
    `amount`      DECIMAL(15,2) NOT NULL DEFAULT 0.00,
    `reason`      VARCHAR(120)  NOT NULL,
    `resolved`    TINYINT(1)    NOT NULL DEFAULT 0,
    `resolved_by` VARCHAR(50)   DEFAULT NULL,
    `resolved_at` DATETIME      DEFAULT NULL,
    `created_at`  DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_pending_refunds_citizenid` (`citizenid`),
    KEY `idx_matrix_pending_refunds_resolved`  (`resolved`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- Convergence: INT -> BIGINT (id kolonu)
SET @prf_id_type := (
    SELECT DATA_TYPE FROM information_schema.columns
    WHERE table_schema = DATABASE()
      AND table_name = 'matrix_pending_refunds'
      AND column_name = 'id'
    LIMIT 1
);
SET @sql_prf_id := IF(@prf_id_type IS NOT NULL AND @prf_id_type <> 'bigint',
    'ALTER TABLE `matrix_pending_refunds` MODIFY COLUMN `id` BIGINT NOT NULL AUTO_INCREMENT',
    'SELECT 1');
PREPARE stmt FROM @sql_prf_id; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- Convergence: DECIMAL(12,2) / DECIMAL(15,2) -> kesin DECIMAL(15,2)
SET @prf_amt_type := (
    SELECT DATA_TYPE FROM information_schema.columns
    WHERE table_schema = DATABASE()
      AND table_name = 'matrix_pending_refunds'
      AND column_name = 'amount'
    LIMIT 1
);
SET @sql_prf_amt := IF(@prf_amt_type IS NOT NULL AND @prf_amt_type <> 'decimal',
    'ALTER TABLE `matrix_pending_refunds` MODIFY COLUMN `amount` DECIMAL(15,2) NOT NULL DEFAULT 0.00',
    'SELECT 1');
PREPARE stmt FROM @sql_prf_amt; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- Convergence: DECIMAL(12,2) -> DECIMAL(15,2) (tip aynı, ölçek dar ise genişlet)
SET @prf_amt_scale := (
    SELECT COALESCE(NUMERIC_SCALE, 2) FROM information_schema.columns
    WHERE table_schema = DATABASE()
      AND table_name = 'matrix_pending_refunds'
      AND column_name = 'amount'
    LIMIT 1
);
SET @sql_prf_scale := IF(@prf_amt_scale IS NOT NULL AND @prf_amt_scale < 2,
    'ALTER TABLE `matrix_pending_refunds` MODIFY COLUMN `amount` DECIMAL(15,2) NOT NULL DEFAULT 0.00',
    'SELECT 1');
PREPARE stmt FROM @sql_prf_scale; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- Convergence: çözüm-takip kolonları eksikse ekle (phase3 şemasından gelmişse)
SET @prf_has_resolved := (
    SELECT COUNT(*) FROM information_schema.columns
    WHERE table_schema = DATABASE()
      AND table_name = 'matrix_pending_refunds'
      AND column_name = 'resolved'
);
SET @sql_prf_res := IF(@prf_has_resolved = 0,
    'ALTER TABLE `matrix_pending_refunds` ADD COLUMN `resolved` TINYINT(1) NOT NULL DEFAULT 0, ADD COLUMN `resolved_by` VARCHAR(50) DEFAULT NULL, ADD COLUMN `resolved_at` DATETIME DEFAULT NULL',
    'SELECT 1');
PREPARE stmt FROM @sql_prf_res; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- ---------------------------------------------------------------------
-- [5] matrix_player_telemetry — EKSİK ŞEMA
-- server/player_telemetry.lua Write-Behind INSERT hedefi (15sn heartbeat).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_player_telemetry` (
    `citizenid`        VARCHAR(50) NOT NULL,
    `active_hours`     TEXT        NULL
        COMMENT 'CSV: 168 değer (7gün x 24saat) — düz metin, JSON değil (CPU dostu)',
    `preferred_zone`   INT         NULL
        COMMENT 'En çok ziyaret edilen zone_id (Config.Market.Zones)',
    `aggression_index` FLOAT       NOT NULL DEFAULT 0.0,
    `escape_pattern`   FLOAT       NOT NULL DEFAULT 0.5,
    `spend_rate`       FLOAT       NOT NULL DEFAULT 0.0,
    `death_frequency`  FLOAT       NOT NULL DEFAULT 0.0,
    `trade_balance`    FLOAT       NOT NULL DEFAULT 0.0,
    `updated_at`       DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`citizenid`),
    KEY `idx_matrix_player_telemetry_preferred_zone` (`preferred_zone`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

SET FOREIGN_KEY_CHECKS = 1;

-- =====================================================================
-- DOĞRULAMA (opsiyonel)
-- =====================================================================
-- SELECT COUNT(*) FROM information_schema.tables
--  WHERE table_schema = DATABASE()
--    AND table_name IN ('matrix_exploit_log','matrix_pending_refunds','matrix_player_telemetry');
--   -- beklenen: 3

-- =====================================================================
-- SESSION 4 — CHEMICAL DILUTION MATRIX ADDITIVE MIGRATION
-- =====================================================================
SET FOREIGN_KEY_CHECKS = 0;

ALTER TABLE `matrix_bureau_learning_core`
    ADD COLUMN IF NOT EXISTS `overdose_raid_score` INT NOT NULL DEFAULT 0
        COMMENT 'SESSION4: street overdose fatality raid score (0..100; 100 -> lockdown)';

SET FOREIGN_KEY_CHECKS = 1;

-- =====================================================================
-- SESSION 4.99 — CELLULAR AUTONOMY ADDITIVE MIGRATION
-- MariaDB 10.4+ / MySQL 8.0+ uyumlu. Idempotent.
-- =====================================================================
SET FOREIGN_KEY_CHECKS = 0;

CREATE TABLE IF NOT EXISTS `matrix_crack_operations` (
    `id`              BIGINT       NOT NULL AUTO_INCREMENT,
    `agent_id`        INT          NOT NULL,
    `cell_id`         INT          NOT NULL,
    `cocaine_mg`      FLOAT        NOT NULL DEFAULT 0.0,
    `bicarbonate_mg`  FLOAT        NOT NULL DEFAULT 0.0,
    `dev_value`       FLOAT        NOT NULL DEFAULT 0.0,
    `agent_iq`        FLOAT        NOT NULL DEFAULT 100.0,
    `started_epoch`   BIGINT       NOT NULL,
    `ends_epoch`      BIGINT       NOT NULL,
    `status`          VARCHAR(20)  NOT NULL DEFAULT 'processing',
    `outcome`         VARCHAR(32)  NULL,
    `created_at`      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_crack_status` (`status`),
    KEY `idx_crack_agent`  (`agent_id`),
    KEY `idx_crack_cell`   (`cell_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `matrix_meth_operations` (
    `id`                BIGINT       NOT NULL AUTO_INCREMENT,
    `agent_id`          INT          NOT NULL,
    `cell_id`           INT          NOT NULL,
    `methylamine_mg`    FLOAT        NOT NULL DEFAULT 0.0,
    `phenylacetone_mg`  FLOAT        NOT NULL DEFAULT 0.0,
    `purity_drop`       FLOAT        NOT NULL DEFAULT 0.0,
    `toxicity`          FLOAT        NOT NULL DEFAULT 0.0,
    `skill_chemistry`   FLOAT        NOT NULL DEFAULT 0.0,
    `started_epoch`     BIGINT       NOT NULL,
    `ends_epoch`        BIGINT       NOT NULL,
    `status`            VARCHAR(20)  NOT NULL DEFAULT 'processing',
    `outcome`           VARCHAR(32)  NULL,
    `created_at`        DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_meth_status` (`status`),
    KEY `idx_meth_agent`  (`agent_id`),
    KEY `idx_meth_cell`   (`cell_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `matrix_botany_autonomy_ops` (
    `id`              BIGINT       NOT NULL AUTO_INCREMENT,
    `agent_id`        INT          NOT NULL,
    `cell_id`         INT          NOT NULL,
    `gel_ml`          FLOAT        NOT NULL DEFAULT 0.0,
    `nitrogen_mg`     FLOAT        NOT NULL DEFAULT 0.0,
    `coeff`           FLOAT        NOT NULL DEFAULT 1.0,
    `started_epoch`   BIGINT       NOT NULL,
    `ends_epoch`      BIGINT       NOT NULL,
    `status`          VARCHAR(20)  NOT NULL DEFAULT 'processing',
    `outcome`         VARCHAR(32)  NULL,
    `created_at`      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_botany_status` (`status`),
    KEY `idx_botany_agent`  (`agent_id`),
    KEY `idx_botany_cell`   (`cell_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

SET FOREIGN_KEY_CHECKS = 1;

-- =====================================================================
-- PROJECT MATRIX — SESSION 1 — PROXY ASSET REGISTRY (BRIDGE)
-- HeidiSQL / MariaDB 10.2+ / MySQL 8.0+ uyumlu düzeltilmiş sürüm.
-- Additive-only. Legacy matrix_trap_houses şemasına DOKUNMAZ.
-- =====================================================================
SET FOREIGN_KEY_CHECKS = 0;

-- ---------------------------------------------------------------------
-- TEMİZ SLATE — şema çakışmasını önlemek için önce temizle
-- (Session 1 ilk kurulumda veri kaybı beklenmez.)
-- ---------------------------------------------------------------------


-- ---------------------------------------------------------------------
-- [1] matrix_traphouses — PROXY ASSET REGISTRY
-- Kısıtlamalar/CHECK'ler ayrı ALTER'ler ile eklenir (HeidiSQL-safe).
-- ---------------------------------------------------------------------
CREATE TABLE `matrix_traphouses` (
    `id`                INT          NOT NULL AUTO_INCREMENT,
    `citizenid`         VARCHAR(50)  NOT NULL,
    `house_name`        VARCHAR(100) NOT NULL,
    `coords`            LONGTEXT     NOT NULL
        COMMENT 'JSON string layout: {"x":..,"y":..,"z":..} — legacy FLOAT bridge',
    `house_size`        VARCHAR(20)  NOT NULL DEFAULT 'small'
        COMMENT 'small | medium | large',
    `max_house_limit`   INT          NOT NULL DEFAULT 1
        COMMENT 'dinamik operasyonel ust sinir (hard cap 3)',
    `last_tax_payment`  INT          NOT NULL
        COMMENT 'Unix timestamp (os.time) — son basarili FinCEN audit',
    `is_sealed`         TINYINT      NOT NULL DEFAULT 0
        COMMENT '1 = audit fail / tactical lockdown',
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- UNIQUE kısıtlaması (ayrı ALTER — HeidiSQL-safe)
ALTER TABLE `matrix_traphouses`
    ADD CONSTRAINT `unique_citizen_house_limit`
    UNIQUE (`citizenid`, `id`);

-- CHECK kısıtlamaları (MariaDB 10.2+ / MySQL 8.0.16+ destekler)
ALTER TABLE `matrix_traphouses`
    ADD CONSTRAINT `chk_matrix_traphouses_size`
    CHECK (`house_size` IN ('small','medium','large'));

ALTER TABLE `matrix_traphouses`
    ADD CONSTRAINT `chk_matrix_traphouses_limit`
    CHECK (`max_house_limit` BETWEEN 1 AND 3);

ALTER TABLE `matrix_traphouses`
    ADD CONSTRAINT `chk_matrix_traphouses_sealed`
    CHECK (`is_sealed` IN (0, 1));

-- İndeksler (ayrı ayrı, hata durumunda izole edilebilir)
CREATE INDEX `idx_matrix_traphouses_citizenid`
    ON `matrix_traphouses` (`citizenid`);

CREATE INDEX `idx_matrix_traphouses_sealed_tax`
    ON `matrix_traphouses` (`is_sealed`, `last_tax_payment`);




SET FOREIGN_KEY_CHECKS = 1;

-- =====================================================================
-- DOĞRULAMA (opsiyonel, elle çalıştırın)
-- =====================================================================
-- SELECT COUNT(*) AS tbl FROM information_schema.tables
--  WHERE table_schema = DATABASE() AND table_name = 'matrix_traphouses';   -- beklenen: 1
-- SELECT COUNT(*) AS vw  FROM information_schema.views
--  WHERE table_schema = DATABASE() AND table_name = 'matrix_agent_pool';   -- beklenen: 1
-- SELECT COUNT(*) AS log FROM information_schema.tables
--  WHERE table_schema = DATABASE() AND table_name = 'matrix_exploit_log';  -- beklenen: 1


-- =====================================================================
-- SESSION 2 — BOT KİŞİLİK / UZMANLIK SİSTEMİ (Personality + Specialty)
-- Deterministik üretim: dna_id'den türetilir, 0 RNG.
-- =====================================================================
SET FOREIGN_KEY_CHECKS = 0;

ALTER TABLE `matrix_bots`
    ADD COLUMN IF NOT EXISTS `personality` JSON NULL
        COMMENT 'Kişilik profili: patience, aggression, caution, loyalty, temperament',
    ADD COLUMN IF NOT EXISTS `specialty` JSON NULL
        COMMENT 'Uzmanlık profili: primary, secondary, bonus, bonus2';

SET FOREIGN_KEY_CHECKS = 1;

-- =====================================================================
-- ★★★ FAZ 2.3 — CİNAYET → HEAT → RAID ZİNCİRİ (KALICI KAYIT) ★★★
-- [MATRIX:INTELLIGENCE_CHAIN_PHASE2_3]
--
-- Additive-only. Mevcut hiçbir tablo/kolon DEĞİŞTİRİLMEZ.
-- FAZ 2.1+2.2'de RAM'de 5 saniye yaşayan cinayet tespitini + tanık
-- FOV/LOS taramasını KALICI hale getirir. Cinayet + tanık ifadesi DB'ye
-- yazılır, heat zinciri bu kayıtlardan beslenir, FAZ 3'te mahkeme
-- birleşik delil olarak okur.
--
-- TASARIM KARARLARI:
--   1. Cinayet kaydı İKİSİ İÇİN (oyuncu + AI) — simetri ilkesi.
--   2. Tanık HEM oyuncu HEM AI (kitapta __ScanWitnesses zaten ikisini
--      tarıyor).
--   3. Killer kimliği mahkemede AÇIK isim + DNA (adil oyun).
--   4. Mahkumiyet skoru FAZ 2.3'te SADECE VERİ olarak birikir
--      (confidence_final); tam skor + birleşik delil FAZ 3'te.
-- =====================================================================

SET FOREIGN_KEY_CHECKS = 0;

-- ---------------------------------------------------------------------
-- [1] matrix_crime_log — KALICI CİNAYET KAYDI
-- Adli kayıt politikası: ASLA silinmez. resolved bayrağı yalnızca
-- mahkeme/raid zincirinin kapandığını işaretler; satır KALIR.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_crime_log` (
    `id`                BIGINT       NOT NULL AUTO_INCREMENT,

    -- Mağdur (victim)
    `victim_kind`       VARCHAR(16)  NOT NULL DEFAULT 'unknown'
        COMMENT 'player|bot|unknown',
    `victim_id`         VARCHAR(64)  NULL
        COMMENT 'player için src sayısı, bot için bot_id (string)',
    `victim_dna`        VARCHAR(64)  NULL,
    `victim_citizenid`  VARCHAR(50)  NULL
        COMMENT 'Yalnızca victim_kind=player ise dolu',

    -- Fail (killer / attacker)
    `killer_kind`       VARCHAR(24)  NOT NULL DEFAULT 'unknown'
        COMMENT 'player|bot|self_or_environment|unknown',
    `killer_id`         VARCHAR(64)  NULL,
    `killer_dna`        VARCHAR(64)  NULL,
    `killer_citizenid`  VARCHAR(50)  NULL,

    -- Olay yeri
    `coords_x`          FLOAT        NOT NULL DEFAULT 0.0,
    `coords_y`          FLOAT        NOT NULL DEFAULT 0.0,
    `coords_z`          FLOAT        NOT NULL DEFAULT 0.0,
    `nearest_trap_id`   INT          NULL
        COMMENT 'Olay anında en yakın trap house (heat zinciri hedefi)',

    -- Tanık özeti
    `witness_count`     INT          NOT NULL DEFAULT 0,
    `witness_players`   INT          NOT NULL DEFAULT 0
        COMMENT 'Sadece oyuncu tanıklar (alt sayaç)',
    `witness_bots`      INT          NOT NULL DEFAULT 0
        COMMENT 'Sadece AI tanıklar (alt sayaç)',

    -- Mahkeme ön-hazırlığı (FAZ 3'te tam skor formülü)
    `confidence_final`  FLOAT        NOT NULL DEFAULT 0.0
        COMMENT 'FAZ 3 mahkumiyet skoru için ham veri — [0,1]',

    -- Yaşam döngüsü
    `occurred_at`       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `resolved`          TINYINT(1)   NOT NULL DEFAULT 0
        COMMENT 'Mahkeme/raid zinciri kapandı mı (satır SİLİNMEZ)',
    `resolved_at`       DATETIME     NULL,

    PRIMARY KEY (`id`),
    KEY `idx_crime_log_occurred`   (`occurred_at`),
    KEY `idx_crime_log_victim`     (`victim_kind`, `victim_id`),
    KEY `idx_crime_log_killer`     (`killer_kind`, `killer_id`),
    KEY `idx_crime_log_nearest`    (`nearest_trap_id`),
    KEY `idx_crime_log_resolved`   (`resolved`, `occurred_at`),
    CONSTRAINT `fk_crime_log_nearest_trap`
        FOREIGN KEY (`nearest_trap_id`) REFERENCES `matrix_trap_houses` (`id`)
        ON DELETE SET NULL
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- ---------------------------------------------------------------------
-- [2] matrix_witness_statements — TANIK İFADESİ + DETERMİNİSTİK GÜVEN
-- Her cinayet için N satır (N = witness_count). Aynı tanığın aynı
-- cinayete iki kez yazılmasını WITNESS_DEDUPE_MS (5000) Lua'da engeller.
--
-- confidence: 0.0-1.0, Lua'da DETERMİNİSTİK formül (RNG YOK):
--   base   = 1.0
--   dist_f = max(0, (WITNESS_RADIUS - dist) / WITNESS_RADIUS)  -- [0,1]
--   los_f  = 1.0 (LOS varsa) / 0.3 (yoksa — zaten kaydedilmez)
--   kind_f = 1.00 (bot tanık — deterministik görüş)
--          / 0.85 (player tanık — bildiğini iddia eder)
--   confidence = clamp(base * dist_f * los_f * kind_f, 0.0, 1.0)
-- =====================================================================
CREATE TABLE IF NOT EXISTS `matrix_witness_statements` (
    `id`                  BIGINT       NOT NULL AUTO_INCREMENT,
    `crime_id`            BIGINT       NOT NULL,

    -- Tanık kimliği
    `witness_kind`        VARCHAR(16)  NOT NULL DEFAULT 'unknown'
        COMMENT 'player|bot',
    `witness_id`          VARCHAR(64)  NULL,
    `witness_dna`         VARCHAR(64)  NULL,
    `witness_citizenid`   VARCHAR(50)  NULL,

    -- Tanıklık ölçüm verileri (FOV/LOS tarama sonucu)
    `distance_m`          FLOAT        NOT NULL DEFAULT 0.0
        COMMENT 'Cinayet anındaki mağdur-tanık mesafesi (m)',
    `in_fov`              TINYINT(1)   NOT NULL DEFAULT 1,
    `had_los`             TINYINT(1)   NOT NULL DEFAULT 1,

    -- Deterministik güven skoru (Lua hesaplar, SQL saklar)
    `confidence`          FLOAT        NOT NULL DEFAULT 0.0
        COMMENT '[0,1] — kind_f ve dist_f ile deterministik',

    -- Zaman
    `statement_at`        DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (`id`),
    KEY `idx_witness_crime`   (`crime_id`),
    KEY `idx_witness_kind`    (`witness_kind`, `witness_id`),
    KEY `idx_witness_dna`     (`witness_dna`),
    CONSTRAINT `fk_witness_crime`
        FOREIGN KEY (`crime_id`) REFERENCES `matrix_crime_log` (`id`)
        ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

SET FOREIGN_KEY_CHECKS = 1;

-- =====================================================================
-- DOĞRULAMA (opsiyonel)
-- SELECT COUNT(*) FROM information_schema.tables
--  WHERE table_schema = DATABASE()
--    AND table_name IN ('matrix_crime_log','matrix_witness_statements');
--   -- beklenen: 2
-- =====================================================================


-- =====================================================================
-- ★★★ FAZ 2.4 — LSPD ARANMA + KALICI BÖLGE MÜHRÜ ★★★
-- [MATRIX:LSPD_WANTED_PHASE2_4]
-- Additive-only. Mevcut hiçbir tablo/kolon DEĞİŞTİRİLMEZ.
-- =====================================================================

SET FOREIGN_KEY_CHECKS = 0;

-- ---------------------------------------------------------------------
-- [1] matrix_sealed_zones — Kalıcı bölge mührü (75m yarıçap, 7 gün)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_sealed_zones` (
    `id`                 BIGINT       NOT NULL AUTO_INCREMENT,
    `coord_x`            FLOAT        NOT NULL,
    `coord_y`            FLOAT        NOT NULL,
    `coord_z`            FLOAT        NOT NULL,
    `radius_m`           FLOAT        NOT NULL DEFAULT 75.0,
    `reason`             VARCHAR(32)  NOT NULL DEFAULT 'raid'
        COMMENT 'raid|crime_chain|bureau_lockdown',
    `source_trap_id`     INT          NULL,
    `source_crime_id`    BIGINT       NULL,
    `sealed_at`          DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `sealed_until_epoch` BIGINT       NOT NULL,
    `active`             TINYINT(1)   NOT NULL DEFAULT 1,
    PRIMARY KEY (`id`),
    KEY `idx_zone_active` (`active`, `sealed_until_epoch`),
    KEY `idx_zone_coord`  (`coord_x`, `coord_y`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- ---------------------------------------------------------------------
-- [2] matrix_wanted_persons — Aranan kişiler (oyuncu + AI)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_wanted_persons` (
    `id`               BIGINT       NOT NULL AUTO_INCREMENT,
    `person_kind`      VARCHAR(16)  NOT NULL
        COMMENT 'player|bot',
    `person_id`        VARCHAR(64)  NULL,
    `person_dna`       VARCHAR(64)  NULL,
    `person_citizenid` VARCHAR(50)  NULL,
    `crime_ids`        TEXT         NULL
        COMMENT 'JSON array: cinayet kayit id leri',
    `heat_level`       INT          NOT NULL DEFAULT 1
        COMMENT '1-5 yildiz',
    `reason`           VARCHAR(64)  NOT NULL DEFAULT 'murder',
    `issued_by_unit`   VARCHAR(32)  NOT NULL DEFAULT 'istihbarat'
        COMMENT 'asayis|narkotik|mali|siber|istihbarat',
    `issued_at`        DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `cleared`          TINYINT(1)   NOT NULL DEFAULT 0,
    `cleared_at`       DATETIME     NULL,
    `cleared_reason`   VARCHAR(32)  NULL,
    PRIMARY KEY (`id`),
    KEY `idx_wanted_kind`    (`person_kind`, `person_id`),
    KEY `idx_wanted_cleared` (`cleared`, `issued_at`),
    KEY `idx_wanted_dna`     (`person_dna`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- ---------------------------------------------------------------------
-- [3] matrix_lspd_units — 5 birim iskelet (FAZ 3'te derinleşir)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_lspd_units` (
    `unit_code`           VARCHAR(32)  NOT NULL,
    `label`               VARCHAR(64)  NOT NULL,
    `focus`               VARCHAR(128) NOT NULL,
    `priority_multiplier` FLOAT        NOT NULL DEFAULT 1.0,
    `active`              TINYINT(1)   NOT NULL DEFAULT 1,
    `updated_at`          DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`unit_code`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

INSERT INTO `matrix_lspd_units` (unit_code, label, focus, priority_multiplier) VALUES
    ('asayis',     'Asayis',      'Sokak devriyesi, genel asayis',       1.0),
    ('narkotik',   'Narkotik',    'Uyusturucu operasyonlari',            1.5),
    ('mali',       'Mali Suclar', 'Kara para, vergi kacakciligi',        1.2),
    ('siber',      'Siber Suclar','Kripto, darknet, hack',               1.3),
    ('istihbarat', 'Istihbarat',  'Cinayet, cete takibi',                1.4)
ON DUPLICATE KEY UPDATE
    label               = VALUES(label),
    focus               = VALUES(focus),
    priority_multiplier = VALUES(priority_multiplier);

-- ---------------------------------------------------------------------
-- [4] matrix_lspd_activity_log — Adli aksiyon kaydı (asla silinmez)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_lspd_activity_log` (
    `id`          BIGINT       NOT NULL AUTO_INCREMENT,
    `unit_code`   VARCHAR(32)  NOT NULL,
    `action`      VARCHAR(32)  NOT NULL
        COMMENT 'wanted_issued|wanted_cleared|zone_sealed|zone_unsealed',
    `target_kind` VARCHAR(16)  NULL,
    `target_id`   VARCHAR(64)  NULL,
    `target_dna`  VARCHAR(64)  NULL,
    `coord_x`     FLOAT        NULL,
    `coord_y`     FLOAT        NULL,
    `coord_z`     FLOAT        NULL,
    `detail`      VARCHAR(255) NULL,
    `created_at`  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_lspd_log_unit`   (`unit_code`, `created_at`),
    KEY `idx_lspd_log_action` (`action`, `created_at`),
    KEY `idx_lspd_log_target` (`target_kind`, `target_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- ---------------------------------------------------------------------
-- [5] ALTER matrix_trap_houses — bölge mührü kolonları
-- ---------------------------------------------------------------------
ALTER TABLE `matrix_trap_houses`
    ADD COLUMN IF NOT EXISTS `sealed`             TINYINT(1) NOT NULL DEFAULT 0
        COMMENT 'FAZ 2.4 — bolge muhru aktif mi',
    ADD COLUMN IF NOT EXISTS `sealed_at_epoch`    BIGINT NULL,
    ADD COLUMN IF NOT EXISTS `sealed_until_epoch` BIGINT NULL,
    ADD COLUMN IF NOT EXISTS `sealed_reason`      VARCHAR(32) NULL,
    ADD COLUMN IF NOT EXISTS `sealed_zone_id`     BIGINT NULL
        COMMENT 'FK matrix_sealed_zones.id';

SET FOREIGN_KEY_CHECKS = 1;

SELECT '[FAZ 2.4] LSPD wanted + sealed zones hazir.' AS durum;


-- =====================================================================
-- ★★★ FAZ 2.5 EK — COMBAT LOG DEBRIEF (QUIT META-GERİBİLDİRİM) ★★★
-- [MATRIX:COMBAT_DEBRIEF_PHASE2_5]
--
-- Additive-only. Mevcut hiçbir tablo/kolon DEĞİŞTİRİLMEZ.
-- Oyuncu quit atınca ortam değerlendirmesi yapılır, deterministik tehdit
-- skoru hesaplanır, DB'ye yazılır. CEZALANDIRMA YOK — sadece farkındalık.
--
-- 3 FAKTÖR (kitap tasarımı):
--   1. wanted_level (0-5)          → ağırlık 0.40
--   2. son 60sn cinayet sayısı     → ağırlık 0.35
--   3. yakın polis/tanık yoğunluğu → ağırlık 0.25
--
-- DETERMİNİSTİK JİTTER: RNG YOK. citizenid + son olay + severity
-- checksum'ından türetilir → aynı girdi her zaman aynı jitter'ı verir.
-- =====================================================================

SET FOREIGN_KEY_CHECKS = 0;

-- ---------------------------------------------------------------------
-- [1] matrix_debrief_log — Oyuncu quit değerlendirmesi
-- Adli kayıt politikası: ASLA silinmez (meta-geribildirim arşivi).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_debrief_log` (
    `id`                BIGINT       NOT NULL AUTO_INCREMENT,
    `citizenid`         VARCHAR(50)  NOT NULL,

    -- Tehdit skoru
    `final_score`       TINYINT      NOT NULL DEFAULT 0
        COMMENT '0-100 — jitter dahil nihai skor',
    `raw_score`         DECIMAL(5,2) NOT NULL DEFAULT 0.00
        COMMENT '0-100 — jitter öncesi ham skor',
    `jitter`            TINYINT      NOT NULL DEFAULT 0
        COMMENT '-10..+10 — deterministik checksum türevi',

    -- Faktör detayları (mahkemede şeffaflık)
    `wanted_level`      TINYINT      NOT NULL DEFAULT 0,
    `crimes_60s`        TINYINT      NOT NULL DEFAULT 0,
    `nearby_police`     TINYINT      NOT NULL DEFAULT 0,
    `avg_crime_conf`    DECIMAL(4,3) NOT NULL DEFAULT 0.000
        COMMENT 'Son 60sn cinayetlerin ortalama confidence değeri',

    -- Referans
    `last_crime_id`     BIGINT       NULL
        COMMENT 'Son cinayet kaydının id si (matrix_crime_log.id)',

    -- Zaman
    `evaluated_at`      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (`id`),
    KEY `idx_debrief_citizenid`    (`citizenid`),
    KEY `idx_debrief_evaluated`    (`evaluated_at`),
    KEY `idx_debrief_score`        (`final_score`),
    KEY `idx_debrief_crimes_60s`   (`crimes_60s`),
    CONSTRAINT `fk_debrief_last_crime`
        FOREIGN KEY (`last_crime_id`) REFERENCES `matrix_crime_log` (`id`)
        ON DELETE SET NULL
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

SET FOREIGN_KEY_CHECKS = 1;

-- =====================================================================
-- DOĞRULAMA (opsiyonel)
-- SELECT COUNT(*) FROM information_schema.tables
--  WHERE table_schema = DATABASE()
--    AND table_name = 'matrix_debrief_log';
--   -- beklenen: 1
-- =====================================================================

SELECT '[FAZ 2.5 EK] Combat Log Debrief hazir.' AS durum;

-- =====================================================================
-- ★★★ FAZ 2.5 — POZİSYON SİSTEMİ (7 SLOT × 5 TİP) ★★★
-- [MATRIX:POSITIONS_PHASE2_5]
-- Additive-only. Mevcut tabloya/kolona DOKUNMAZ.
-- =====================================================================
SET FOREIGN_KEY_CHECKS = 0;

CREATE TABLE IF NOT EXISTS `matrix_positions` (
    `id`                  BIGINT       NOT NULL AUTO_INCREMENT,
    `trap_house_id`       INT          NOT NULL,
    `slot_index`          TINYINT      NOT NULL
        COMMENT '1-7 arası slot index',
    `slot_type`           VARCHAR(16)  NOT NULL
        COMMENT 'gate|roof|hub|inner|escape',
    `side`                VARCHAR(16)  NOT NULL DEFAULT 'defense'
        COMMENT 'defense|attack (şimdilik sadece defense)',

    -- Birincil nokta
    `coord_x`             FLOAT        NOT NULL,
    `coord_y`             FLOAT        NOT NULL,
    `coord_z`             FLOAT        NOT NULL,
    `heading`             FLOAT        NOT NULL DEFAULT 0.0,

    -- Yedek nokta (ateş altında geçilecek)
    `backup_x`            FLOAT        NULL,
    `backup_y`            FLOAT        NULL,
    `backup_z`            FLOAT        NULL,
    `backup_heading`      FLOAT        NULL,

    -- LOS parametreleri (sayısal bonus YOK, fizik kuralları)
    `los_range_m`         FLOAT        NOT NULL DEFAULT 30.0
        COMMENT 'Görüş mesafesi (metre)',
    `los_fov_deg`         FLOAT        NOT NULL DEFAULT 120.0
        COMMENT 'Görüş açısı (derece)',
    `los_pitch_min`       FLOAT        NOT NULL DEFAULT -30.0
        COMMENT 'Dikey görüş alt sınırı (derece)',
    `los_pitch_max`       FLOAT        NOT NULL DEFAULT 45.0
        COMMENT 'Dikey görüş üst sınırı (derece)',

    -- Atama durumu
    `assigned_bot_id`     INT          NULL,
    `assigned_citizenid`  VARCHAR(50)  NULL,
    `assigned_at`         DATETIME     NULL,

    -- Reflex durumu
    `under_fire`          TINYINT(1)   NOT NULL DEFAULT 0,
    `last_fire_at`        DATETIME     NULL,
    `using_backup`        TINYINT(1)   NOT NULL DEFAULT 0,

    `created_at`          DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at`          DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_position_slot` (`trap_house_id`, `slot_index`, `side`),
    KEY `idx_position_assigned_bot`  (`assigned_bot_id`),
    KEY `idx_position_assigned_cid`  (`assigned_citizenid`),
    KEY `idx_position_under_fire`    (`under_fire`, `last_fire_at`),
    CONSTRAINT `fk_position_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
        ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

SET FOREIGN_KEY_CHECKS = 1;

SELECT '[FAZ 2.5] matrix_positions hazir.' AS durum;

CREATE TABLE IF NOT EXISTS `matrix_missions` (
  `id` INT NOT NULL AUTO_INCREMENT,
  `mission_type` ENUM('uretim','nakliye','sabotaj','infaz') NOT NULL,
  `giver_bot_id` INT NULL,
  `assignee_citizenid` VARCHAR(64) NULL,
  `state` ENUM('offered','accepted','in_progress','completed','failed')
         NOT NULL DEFAULT 'offered',
  `target_payload` JSON NULL,
  `reward_cash` INT NOT NULL DEFAULT 0,
  `reward_rep`  INT NOT NULL DEFAULT 0,
  `reward_heat` INT NOT NULL DEFAULT 0,
  `deadline_tick` BIGINT NULL,
  `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  `updated_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_assignee_state` (`assignee_citizenid`,`state`),
  KEY `idx_state_deadline` (`state`,`deadline_tick`),
  CONSTRAINT `fk_missions_giver`
    FOREIGN KEY (`giver_bot_id`) REFERENCES `matrix_bots`(`id`)
    ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;