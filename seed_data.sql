-- ====================================================================
-- Store Manager Pro: Canonical Safe Seed Data
-- Safe Bootstrap: No hardcoded credentials, no plaintext secrets
-- ====================================================================

-- 1. Default Tenant (Independent Single-Store License)
INSERT INTO tenants (id, name, is_active) 
VALUES ('TENANT_DEFAULT', 'المتجر الرئيسي المستقل', 1);

-- 2. Default Store & Central Warehouse
INSERT INTO stores (id, tenant_id, code, name, address, phone, is_active) 
VALUES ('STORE_DEFAULT', 'TENANT_DEFAULT', 'MAIN_STORE', 'المتجر الرئيسي', 'الجزائر العاصمة', '0550000000', 1);

INSERT INTO warehouses (id, tenant_id, store_id, name, is_default, is_active) 
VALUES ('WH_DEFAULT', 'TENANT_DEFAULT', 'STORE_DEFAULT', 'المستودع المركزي الرئيسي', 1, 1);

-- 3. Base Currency (DZD) & Common Units of Measure
INSERT INTO currencies (code, name, symbol, decimal_places, is_base) 
VALUES ('DZD', 'دينار جزائري', 'دج', 2, 1);

INSERT INTO units_of_measure (id, dimension, name_ar, name_fr, symbol, is_fractional) 
VALUES ('UOM_PIECE', 'COUNT', 'قطعة', 'Pièce', 'قطعة', 0);

INSERT INTO units_of_measure (id, dimension, name_ar, name_fr, symbol, is_fractional) 
VALUES ('UOM_KG', 'WEIGHT', 'كيلوغرام', 'Kilogramme', 'كغ', 1);

INSERT INTO units_of_measure (id, dimension, name_ar, name_fr, symbol, is_fractional) 
VALUES ('UOM_GRAM', 'WEIGHT', 'غرام', 'Gramme', 'غ', 1);

INSERT INTO units_of_measure (id, dimension, name_ar, name_fr, symbol, is_fractional) 
VALUES ('UOM_METER', 'LENGTH', 'متر', 'Mètre', 'م', 1);

INSERT INTO units_of_measure (id, dimension, name_ar, name_fr, symbol, is_fractional) 
VALUES ('UOM_LITER', 'VOLUME', 'لتر', 'Litre', 'ل', 1);

-- 4. Initial System Roles & Permissions
INSERT INTO roles (id, tenant_id, name, description, is_system) 
VALUES ('ROLE_ADMIN', 'TENANT_DEFAULT', 'مدير النظام', 'صلاحيات كاملة لإدارة المتجر والمستخدمين', 1);

INSERT INTO roles (id, tenant_id, name, description, is_system) 
VALUES ('ROLE_CASHIER', 'TENANT_DEFAULT', 'كاشير / بائع', 'تسجيل المبيعات والصندوق والمقبوضات', 1);

INSERT INTO roles (id, tenant_id, name, description, is_system) 
VALUES ('ROLE_STOCK_MANAGER', 'TENANT_DEFAULT', 'مسؤول مخزون', 'إدارة الاستلام والجرد والتحويلات', 1);

-- 5. Default Cash Register
INSERT INTO cash_registers (id, tenant_id, store_id, name, code, is_active)
VALUES ('CR_DEFAULT', 'TENANT_DEFAULT', 'STORE_DEFAULT', 'صندوق نقطة البيع الرئيسية', 'POS-01', 1);
