import sqlite3
import json
import hashlib
import sys

def run_tests():
    sqlite_ver = sqlite3.sqlite_version
    print(f"Executing Test Suite on SQLite version: {sqlite_ver}")
    conn = sqlite3.connect(":memory:")
    conn.execute("PRAGMA foreign_keys = ON;")
    cur = conn.cursor()

    # Load canonical DDL
    with open("canonical_schema.sql", "r", encoding="utf-8") as f:
        schema_sql = f.read()
    cur.executescript(schema_sql)

    # Load safe seed data
    with open("seed_data.sql", "r", encoding="utf-8") as f:
        seed_sql = f.read()
    cur.executescript(seed_sql)

    results = {}

    def test(test_id, name, fn):
        try:
            status, note = fn(cur, conn)
            results[test_id] = (status, name, note)
            print(f"[{test_id}] {status}: {name} ({note})")
        except Exception as e:
            results[test_id] = ("FAIL", name, str(e))
            print(f"[{test_id}] FAIL: {name} - {e}")

    # T01: Schema Creation
    def t01(c, db):
        c.execute("SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';")
        count = c.fetchone()[0]
        assert count == 55, f"Expected 55 tables, found {count}"
        return "PASS", "Created 55 tables exactly"
    test("T01", "Schema creation from scratch", t01)

    # T02: Safe Seed Data
    def t02(c, db):
        c.execute("SELECT count(*) FROM units_of_measure WHERE id='UOM_PIECE';")
        assert c.fetchone()[0] == 1
        c.execute("SELECT count(*) FROM currencies WHERE code='DZD' AND is_base=1;")
        assert c.fetchone()[0] == 1
        return "PASS", "Inserted safe seed data without credentials"
    test("T02", "Safe seed data insertion", t02)

    # T03: Foreign Key Check
    def t03(c, db):
        c.execute("PRAGMA foreign_key_check;")
        errs = c.fetchall()
        assert len(errs) == 0, f"FK errors: {errs}"
        return "PASS", "0 foreign key errors"
    test("T03", "PRAGMA foreign_key_check", t03)

    # T04: Integrity Check
    def t04(c, db):
        c.execute("PRAGMA integrity_check;")
        res = c.fetchone()[0]
        assert res == "ok", f"Integrity check failed: {res}"
        return "PASS", "Integrity check returned ok"
    test("T04", "PRAGMA integrity_check", t04)

    # T05: Reserved > OnHand rejected
    def t05(c, db):
        c.execute("INSERT INTO products (id, tenant_id, base_unit_id, name, has_variants) VALUES ('P_TEST_5', 'TENANT_DEFAULT', 'UOM_PIECE', 'Test 5', 1);")
        c.execute("INSERT INTO stock_items (id, product_id) VALUES ('SI_TEST_5', 'P_TEST_5');")
        try:
            c.execute("INSERT INTO inventory_balances (warehouse_id, stock_item_id, on_hand_ticks, reserved_ticks, current_moving_avg_cost) VALUES ('WH_DEFAULT', 'SI_TEST_5', 100, 200, 0);")
            raise AssertionError("Allowed reserved > on_hand!")
        except sqlite3.IntegrityError:
            return "PASS", "Rejected reserved > on_hand via CHECK constraint"
    test("T05", "Reject reserved > on_hand", t05)

    # T06_1: Offline Quota Item Mismatch
    def t06_1(c, db):
        c.execute("INSERT INTO registered_devices (id, tenant_id, store_id, device_name, device_type, public_key, pairing_status) VALUES ('DEV_T6', 'TENANT_DEFAULT', 'STORE_DEFAULT', 'POS 6', 'ANDROID_POS', 'PUB_6', 'ACTIVE');")
        c.execute("INSERT INTO products (id, tenant_id, base_unit_id, name, has_variants) VALUES ('P_T6_A', 'TENANT_DEFAULT', 'UOM_PIECE', 'Product 6A', 1);")
        c.execute("INSERT INTO stock_items (id, product_id) VALUES ('SI_T6_A', 'P_T6_A');")
        c.execute("INSERT INTO products (id, tenant_id, base_unit_id, name, has_variants) VALUES ('P_T6_B', 'TENANT_DEFAULT', 'UOM_PIECE', 'Product 6B', 1);")
        c.execute("INSERT INTO stock_items (id, product_id) VALUES ('SI_T6_B', 'P_T6_B');")
        
        c.execute("INSERT INTO inventory_quotas (id, tenant_id, device_id, warehouse_id, stock_item_id, quota_quantity_ticks, consumed_quantity_ticks, valid_until, status, signed_token) VALUES ('Q_T6', 'TENANT_DEFAULT', 'DEV_T6', 'WH_DEFAULT', 'SI_T6_A', 10000, 0, '2099-12-31T23:59:59Z', 'ACTIVE', 'SIG6');")
        c.execute("INSERT INTO sales (id, tenant_id, store_id, warehouse_id, device_id, total_amount_centimes, paid_amount, remaining_debt, status) VALUES ('S_T6', 'TENANT_DEFAULT', 'STORE_DEFAULT', 'WH_DEFAULT', 'DEV_T6', 1000, 1000, 0, 'COMPLETED');")
        c.execute("INSERT INTO sale_items (id, sale_id, stock_item_id, quantity_ticks, unit_price_ticks, line_total_centimes) VALUES ('SI_LINE_T6', 'S_T6', 'SI_T6_B', 1000, 100, 1000);")
        
        try:
            c.execute("INSERT INTO sale_item_quota_deductions (id, sale_item_id, quota_id, deducted_quantity_ticks) VALUES ('DED_T6', 'SI_LINE_T6', 'Q_T6', 1000);")
            raise AssertionError("Allowed deduction from mismatched stock item quota!")
        except sqlite3.IntegrityError as e:
            assert 'QUOTA_STOCK_ITEM_MISMATCH' in str(e)
            return "PASS", "Aborted with QUOTA_STOCK_ITEM_MISMATCH"
    test("T06_1", "Reject quota for different stock item", t06_1)

    # T06_2: Offline Quota Warehouse Mismatch
    def t06_2(c, db):
        c.execute("INSERT INTO stores (id, tenant_id, code, name) VALUES ('STORE_WH2', 'TENANT_DEFAULT', 'ST-WH2', 'Branch WH2');")
        c.execute("INSERT INTO warehouses (id, tenant_id, store_id, name) VALUES ('WH_T6_OTHER', 'TENANT_DEFAULT', 'STORE_WH2', 'Warehouse Other');")
        c.execute("INSERT INTO inventory_quotas (id, tenant_id, device_id, warehouse_id, stock_item_id, quota_quantity_ticks, consumed_quantity_ticks, valid_until, status, signed_token) VALUES ('Q_T6_WH_DIFF', 'TENANT_DEFAULT', 'DEV_T6', 'WH_T6_OTHER', 'SI_T6_A', 10000, 0, '2099-12-31T23:59:59Z', 'ACTIVE', 'SIG6');")
        
        c.execute("INSERT INTO sales (id, tenant_id, store_id, warehouse_id, device_id, total_amount_centimes, paid_amount, remaining_debt, status) VALUES ('S_T6_WH', 'TENANT_DEFAULT', 'STORE_DEFAULT', 'WH_DEFAULT', 'DEV_T6', 1000, 1000, 0, 'COMPLETED');")
        c.execute("INSERT INTO sale_items (id, sale_id, stock_item_id, quantity_ticks, unit_price_ticks, line_total_centimes) VALUES ('SI_LINE_T6_WH', 'S_T6_WH', 'SI_T6_A', 1000, 100, 1000);")
        try:
            c.execute("INSERT INTO sale_item_quota_deductions (id, sale_item_id, quota_id, deducted_quantity_ticks) VALUES ('DED_T6_WH', 'SI_LINE_T6_WH', 'Q_T6_WH_DIFF', 1000);")
            raise AssertionError("Allowed deduction from mismatched warehouse quota!")
        except sqlite3.IntegrityError as e:
            assert 'QUOTA_WAREHOUSE_MISMATCH' in str(e)
            return "PASS", "Aborted with QUOTA_WAREHOUSE_MISMATCH"
    test("T06_2", "Reject quota for different warehouse", t06_2)

    # T06_3: Offline Quota Tenant Mismatch
    def t06_3(c, db):
        c.execute("INSERT INTO tenants (id, name) VALUES ('TENANT_2', 'Tenant 2');")
        # Quota with forged or mismatched tenant_id
        c.execute("INSERT INTO inventory_quotas (id, tenant_id, device_id, warehouse_id, stock_item_id, quota_quantity_ticks, consumed_quantity_ticks, valid_until, status, signed_token) VALUES ('Q_T6_TENANT_DIFF', 'TENANT_2', 'DEV_T6', 'WH_DEFAULT', 'SI_T6_A', 10000, 0, '2099-12-31T23:59:59Z', 'ACTIVE', 'SIG_T2');")
        
        try:
            c.execute("INSERT INTO sale_item_quota_deductions (id, sale_item_id, quota_id, deducted_quantity_ticks) VALUES ('DED_T6_TENANT_ERR', 'SI_LINE_T6_WH', 'Q_T6_TENANT_DIFF', 1000);")
            raise AssertionError("Allowed deduction from mismatched tenant quota!")
        except sqlite3.IntegrityError as e:
            assert 'QUOTA_TENANT_MISMATCH' in str(e)
            return "PASS", "Aborted with QUOTA_TENANT_MISMATCH"
    test("T06_3", "Reject quota for different tenant", t06_3)

    # T06_4: Quota Deduction Exceeding Sale Line Quantity
    def t06_4(c, db):
        c.execute("INSERT INTO sales (id, tenant_id, store_id, warehouse_id, device_id, total_amount_centimes, paid_amount, remaining_debt, status) VALUES ('S_T6_QTY', 'TENANT_DEFAULT', 'STORE_DEFAULT', 'WH_DEFAULT', 'DEV_T6', 1000, 1000, 0, 'COMPLETED');")
        c.execute("INSERT INTO sale_items (id, sale_id, stock_item_id, quantity_ticks, unit_price_ticks, line_total_centimes) VALUES ('SI_LINE_T6_QTY', 'S_T6_QTY', 'SI_T6_A', 2000, 100, 200);")
        try:
            c.execute("INSERT INTO sale_item_quota_deductions (id, sale_item_id, quota_id, deducted_quantity_ticks) VALUES ('DED_T6_OVERLINE', 'SI_LINE_T6_QTY', 'Q_T6', 5000);")
            raise AssertionError("Allowed quota deduction exceeding sale line quantity!")
        except sqlite3.IntegrityError as e:
            assert 'QUOTA_DEDUCTION_EXCEEDS_SALE_LINE_QUANTITY' in str(e)
            return "PASS", "Aborted with QUOTA_DEDUCTION_EXCEEDS_SALE_LINE_QUANTITY"
    test("T06_4", "Reject quota deduction exceeding sale item line quantity", t06_4)

    # T07: Quota for different device rejected
    def t07(c, db):
        c.execute("INSERT INTO registered_devices (id, tenant_id, store_id, device_name, device_type, public_key, pairing_status) VALUES ('DEV_T7_A', 'TENANT_DEFAULT', 'STORE_DEFAULT', 'POS 7A', 'ANDROID_POS', 'PUB_7A', 'ACTIVE');")
        c.execute("INSERT INTO registered_devices (id, tenant_id, store_id, device_name, device_type, public_key, pairing_status) VALUES ('DEV_T7_B', 'TENANT_DEFAULT', 'STORE_DEFAULT', 'POS 7B', 'ANDROID_POS', 'PUB_7B', 'ACTIVE');")
        c.execute("INSERT INTO products (id, tenant_id, base_unit_id, name, has_variants) VALUES ('P_T7', 'TENANT_DEFAULT', 'UOM_PIECE', 'Product 7', 1);")
        c.execute("INSERT INTO stock_items (id, product_id) VALUES ('SI_T7', 'P_T7');")
        c.execute("INSERT INTO inventory_quotas (id, tenant_id, device_id, warehouse_id, stock_item_id, quota_quantity_ticks, consumed_quantity_ticks, valid_until, status, signed_token) VALUES ('Q_T7', 'TENANT_DEFAULT', 'DEV_T7_A', 'WH_DEFAULT', 'SI_T7', 10000, 0, '2099-12-31T23:59:59Z', 'ACTIVE', 'SIG7');")
        
        c.execute("INSERT INTO sales (id, tenant_id, store_id, warehouse_id, device_id, total_amount_centimes, paid_amount, remaining_debt, status) VALUES ('S_T7', 'TENANT_DEFAULT', 'STORE_DEFAULT', 'WH_DEFAULT', 'DEV_T7_B', 1000, 1000, 0, 'COMPLETED');")
        c.execute("INSERT INTO sale_items (id, sale_id, stock_item_id, quantity_ticks, unit_price_ticks, line_total_centimes) VALUES ('SI_LINE_T7', 'S_T7', 'SI_T7', 1000, 100, 1000);")
        
        try:
            c.execute("INSERT INTO sale_item_quota_deductions (id, sale_item_id, quota_id, deducted_quantity_ticks) VALUES ('DED_T7', 'SI_LINE_T7', 'Q_T7', 1000);")
            raise AssertionError("Allowed deduction from mismatched device quota!")
        except sqlite3.IntegrityError as e:
            assert 'QUOTA_DEVICE_MISMATCH' in str(e)
            return "PASS", "Aborted with QUOTA_DEVICE_MISMATCH"
    test("T07", "Reject quota deduction for different device", t07)

    # T08: Expired or voided quota rejected
    def t08(c, db):
        c.execute("INSERT INTO inventory_quotas (id, tenant_id, device_id, warehouse_id, stock_item_id, quota_quantity_ticks, consumed_quantity_ticks, valid_until, status, signed_token) VALUES ('Q_T8_EXP', 'TENANT_DEFAULT', 'DEV_T6', 'WH_DEFAULT', 'SI_T6_A', 10000, 0, '2000-01-01T00:00:00Z', 'EXPIRED', 'SIG8');")
        c.execute("INSERT INTO sales (id, tenant_id, store_id, warehouse_id, device_id, total_amount_centimes, paid_amount, remaining_debt, status) VALUES ('S_T8', 'TENANT_DEFAULT', 'STORE_DEFAULT', 'WH_DEFAULT', 'DEV_T6', 1000, 1000, 0, 'COMPLETED');")
        c.execute("INSERT INTO sale_items (id, sale_id, stock_item_id, quantity_ticks, unit_price_ticks, line_total_centimes) VALUES ('SI_LINE_T8', 'S_T8', 'SI_T6_A', 1000, 100, 1000);")
        try:
            c.execute("INSERT INTO sale_item_quota_deductions (id, sale_item_id, quota_id, deducted_quantity_ticks) VALUES ('DED_T8', 'SI_LINE_T8', 'Q_T8_EXP', 1000);")
            raise AssertionError("Allowed deduction from expired quota!")
        except sqlite3.IntegrityError:
            return "PASS", "Aborted expired/inactive quota deduction"
    test("T08", "Reject expired or non-active quota deduction", t08)

    # T09: Quota over-consumption rejected & updates consumed
    def t09(c, db):
        c.execute("INSERT INTO inventory_quotas (id, tenant_id, device_id, warehouse_id, stock_item_id, quota_quantity_ticks, consumed_quantity_ticks, valid_until, status, signed_token) VALUES ('Q_T9', 'TENANT_DEFAULT', 'DEV_T6', 'WH_DEFAULT', 'SI_T6_A', 5000, 0, '2099-12-31T23:59:59Z', 'ACTIVE', 'SIG9');")
        c.execute("INSERT INTO sales (id, tenant_id, store_id, warehouse_id, device_id, total_amount_centimes, paid_amount, remaining_debt, status) VALUES ('S_T9', 'TENANT_DEFAULT', 'STORE_DEFAULT', 'WH_DEFAULT', 'DEV_T6', 500, 500, 0, 'COMPLETED');")
        c.execute("INSERT INTO sale_items (id, sale_id, stock_item_id, quantity_ticks, unit_price_ticks, line_total_centimes) VALUES ('SI_LINE_T9', 'S_T9', 'SI_T6_A', 3000, 100, 300);")
        
        c.execute("INSERT INTO sale_item_quota_deductions (id, sale_item_id, quota_id, deducted_quantity_ticks) VALUES ('DED_T9_1', 'SI_LINE_T9', 'Q_T9', 3000);")
        c.execute("SELECT consumed_quantity_ticks FROM inventory_quotas WHERE id='Q_T9';")
        assert c.fetchone()[0] == 3000, "Quota consumed ticks not updated automatically!"
        
        c.execute("INSERT INTO sales (id, tenant_id, store_id, warehouse_id, device_id, total_amount_centimes, paid_amount, remaining_debt, status) VALUES ('S_T9_B', 'TENANT_DEFAULT', 'STORE_DEFAULT', 'WH_DEFAULT', 'DEV_T6', 500, 500, 0, 'COMPLETED');")
        c.execute("INSERT INTO sale_items (id, sale_id, stock_item_id, quantity_ticks, unit_price_ticks, line_total_centimes) VALUES ('SI_LINE_T9_B', 'S_T9_B', 'SI_T6_A', 2500, 100, 250);")
        try:
            c.execute("INSERT INTO sale_item_quota_deductions (id, sale_item_id, quota_id, deducted_quantity_ticks) VALUES ('DED_T9_2', 'SI_LINE_T9_B', 'Q_T9', 2500);")
            raise AssertionError("Allowed deduction exceeding quota!")
        except sqlite3.IntegrityError as e:
            assert 'QUOTA_CONSUMPTION_EXCEEDS_REMAINING_BALANCE' in str(e)
            return "PASS", "Enforced quota consumption ceiling and atomic update"
    test("T09", "Enforce quota max consumption & atomic increment", t09)

    # T10: Prevent duplicate quota deduction for same sale item
    def t10(c, db):
        try:
            c.execute("INSERT INTO sale_item_quota_deductions (id, sale_item_id, quota_id, deducted_quantity_ticks) VALUES ('DED_T10', 'SI_LINE_T9', 'Q_T9', 1000);")
            raise AssertionError("Allowed duplicate deduction for same sale item and quota!")
        except sqlite3.IntegrityError:
            return "PASS", "Unique constraint prevented duplicate deduction"
    test("T10", "Prevent duplicate quota deduction for same sale item", t10)

    # T11: Transaction Rollback on Quota Failure
    def t11(c, db):
        c.execute("SAVEPOINT sp_sale_t11;")
        c.execute("INSERT INTO sales (id, tenant_id, store_id, warehouse_id, device_id, total_amount_centimes, paid_amount, remaining_debt, status) VALUES ('S_T11', 'TENANT_DEFAULT', 'STORE_DEFAULT', 'WH_DEFAULT', 'DEV_T6', 100, 100, 0, 'DRAFT');")
        c.execute("INSERT INTO sale_items (id, sale_id, stock_item_id, quantity_ticks, unit_price_ticks, line_total_centimes) VALUES ('SI_T11', 'S_T11', 'SI_T6_A', 999999, 10, 100);")
        failed = False
        try:
            c.execute("INSERT INTO sale_item_quota_deductions (id, sale_item_id, quota_id, deducted_quantity_ticks) VALUES ('DED_T11', 'SI_T11', 'Q_T9', 999999);")
        except sqlite3.IntegrityError:
            failed = True
            c.execute("ROLLBACK TO sp_sale_t11;")
        assert failed, "Expected quota deduction to fail"
        c.execute("SELECT count(*) FROM sales WHERE id='S_T11';")
        assert c.fetchone()[0] == 0, "Sale record should be rolled back cleanly!"
        c.execute("RELEASE sp_sale_t11;")
        return "PASS", "Atomic rollback executed cleanly with 0 leftover rows"
    test("T11", "Atomic rollback when quota deduction fails during sale transaction", t11)

    # T12: Device Signature Storage & Sequence Tracking
    def t12(c, db):
        c.execute("INSERT INTO sales (id, tenant_id, store_id, warehouse_id, device_id, device_seq_num, device_signature, request_hash, total_amount_centimes, paid_amount, remaining_debt, status) VALUES ('S_SIG_VALID', 'TENANT_DEFAULT', 'STORE_DEFAULT', 'WH_DEFAULT', 'DEV_T6', 10, 'SIG_ED25519_VALID', 'HASH123', 500, 500, 0, 'COMPLETED');")
        c.execute("SELECT device_seq_num, device_signature FROM sales WHERE id='S_SIG_VALID';")
        row = c.fetchone()
        assert row[0] == 10 and row[1] == 'SIG_ED25519_VALID'
        c.execute("SELECT last_seq_num FROM registered_devices WHERE id='DEV_T6';")
        assert c.fetchone()[0] == 10, "Device last_seq_num not updated automatically!"
        return "PASS", "Saved signature and automatically updated device sequence to 10"
    test("T12", "Device signature and sequence metadata tracking on sales", t12)

    # T13: Mathematical Cryptographic Ed25519 Verification (Pure Cryptographic check)
    def t13(c, db):
        return "NOT RUN", "Requires JVM / Android Keystore / PyNaCl; separated from SQL storage"
    test("T13", "Mathematical cryptographic Ed25519 signature verification", t13)

    # T14_1: Replay attack prevention via UNIQUE(device_id, local_operation_uuid)
    def t14_1(c, db):
        c.execute("INSERT INTO sales (id, tenant_id, store_id, warehouse_id, device_id, local_operation_uuid, device_seq_num, total_amount_centimes, paid_amount, remaining_debt, status) VALUES ('S_REPLAY_1', 'TENANT_DEFAULT', 'STORE_DEFAULT', 'WH_DEFAULT', 'DEV_T6', 'UUID_DEV6_001', 11, 500, 500, 0, 'COMPLETED');")
        try:
            c.execute("INSERT INTO sales (id, tenant_id, store_id, warehouse_id, device_id, local_operation_uuid, device_seq_num, total_amount_centimes, paid_amount, remaining_debt, status) VALUES ('S_REPLAY_2', 'TENANT_DEFAULT', 'STORE_DEFAULT', 'WH_DEFAULT', 'DEV_T6', 'UUID_DEV6_001', 12, 500, 500, 0, 'COMPLETED');")
            raise AssertionError("Allowed replaying sale with same local_operation_uuid for device!")
        except sqlite3.IntegrityError:
            return "PASS", "Rejected duplicate local_operation_uuid"
    test("T14_1", "Replay attack prevention via UNIQUE(device_id, local_operation_uuid)", t14_1)

    # T14_2: Replay attack prevention via Stale Device Sequence with New UUID
    def t14_2(c, db):
        try:
            c.execute("INSERT INTO sales (id, tenant_id, store_id, warehouse_id, device_id, local_operation_uuid, device_seq_num, total_amount_centimes, paid_amount, remaining_debt, status) VALUES ('S_REPLAY_STALE_SEQ', 'TENANT_DEFAULT', 'STORE_DEFAULT', 'WH_DEFAULT', 'DEV_T6', 'BRAND_NEW_UUID_999', 5, 500, 500, 0, 'COMPLETED');")
            raise AssertionError("Allowed stale device sequence number!")
        except sqlite3.IntegrityError as e:
            assert 'STALE_DEVICE_SEQUENCE_NUMBER_REPLAY_DETECTED' in str(e)
            return "PASS", "Aborted stale sequence replay with STALE_DEVICE_SEQUENCE_NUMBER_REPLAY_DETECTED"
    test("T14_2", "Reject replay with stale sequence number and new UUID", t14_2)

    # T15: Payment allocation party_type check
    def t15(c, db):
        c.execute("INSERT INTO customers (id, tenant_id, name) VALUES ('CUST_T15', 'TENANT_DEFAULT', 'Customer 15');")
        c.execute("INSERT INTO suppliers (id, tenant_id, name) VALUES ('SUPP_T15', 'TENANT_DEFAULT', 'Supplier 15');")
        c.execute("INSERT INTO sales (id, tenant_id, store_id, warehouse_id, customer_id, device_id, total_amount_centimes, paid_amount, remaining_debt, status) VALUES ('S_T15', 'TENANT_DEFAULT', 'STORE_DEFAULT', 'WH_DEFAULT', 'CUST_T15', 'DEV_T6', 10000, 0, 10000, 'COMPLETED');")
        c.execute("INSERT INTO payments (id, tenant_id, store_id, party_type, party_id, payment_method, amount) VALUES ('PAY_SUPP_15', 'TENANT_DEFAULT', 'STORE_DEFAULT', 'SUPPLIER', 'SUPP_T15', 'CASH', 5000);")
        try:
            c.execute("INSERT INTO payment_allocations (id, payment_id, sale_id, allocated_amount) VALUES ('ALLOC_ERR_15', 'PAY_SUPP_15', 'S_T15', 5000);")
            raise AssertionError("Allowed supplier payment allocated to customer sale!")
        except sqlite3.IntegrityError as e:
            assert 'PAYMENT_PARTY_TYPE_MUST_BE_CUSTOMER_FOR_SALE_ALLOCATION' in str(e)
            return "PASS", "Aborted with PAYMENT_PARTY_TYPE_MUST_BE_CUSTOMER"
    test("T15", "Reject payment allocation party_type mismatch", t15)

    # T16: Payment over-allocation
    def t16(c, db):
        c.execute("INSERT INTO payments (id, tenant_id, store_id, party_type, party_id, payment_method, amount) VALUES ('PAY_CUST_16', 'TENANT_DEFAULT', 'STORE_DEFAULT', 'CUSTOMER', 'CUST_T15', 'CASH', 2000);")
        try:
            c.execute("INSERT INTO payment_allocations (id, payment_id, sale_id, allocated_amount) VALUES ('ALLOC_ERR_16', 'PAY_CUST_16', 'S_T15', 3000);")
            raise AssertionError("Allowed allocation exceeding payment amount!")
        except sqlite3.IntegrityError:
            return "PASS", "Rejected payment allocation exceeding payment amount"
    test("T16", "Reject payment over-allocation", t16)

    # T17: Payment reversal mechanism
    def t17(c, db):
        c.execute("INSERT INTO payment_allocations (id, payment_id, sale_id, allocated_amount) VALUES ('ALLOC_OK_17', 'PAY_CUST_16', 'S_T15', 2000);")
        c.execute("SELECT paid_amount, remaining_debt FROM sales WHERE id='S_T15';")
        r = c.fetchone()
        assert r[0] == 2000 and r[1] == 8000
        
        c.execute("INSERT INTO payments (id, tenant_id, store_id, party_type, party_id, payment_method, amount, is_reversal, reversal_of_id) VALUES ('PAY_REV_17', 'TENANT_DEFAULT', 'STORE_DEFAULT', 'CUSTOMER', 'CUST_T15', 'CASH', 2000, 1, 'PAY_CUST_16');")
        c.execute("INSERT INTO payment_allocations (id, payment_id, sale_id, allocated_amount) VALUES ('ALLOC_REV_17', 'PAY_REV_17', 'S_T15', -2000);")
        c.execute("SELECT paid_amount, remaining_debt FROM sales WHERE id='S_T15';")
        r2 = c.fetchone()
        assert r2[0] == 0 and r2[1] == 10000, f"Expected debt 10000 after reversal, got {r2[1]}"
        return "PASS", "Restored debt balance to 10000 via atomic reversal allocation"
    test("T17", "Payment reversal restores debt balance atomically", t17)

    # T18: Prevent duplicate reversal of same payment
    def t18(c, db):
        try:
            c.execute("INSERT INTO payments (id, tenant_id, store_id, party_type, party_id, payment_method, amount, is_reversal, reversal_of_id) VALUES ('PAY_REV_18_DUP', 'TENANT_DEFAULT', 'STORE_DEFAULT', 'CUSTOMER', 'CUST_T15', 'CASH', 2000, 1, 'PAY_CUST_16');")
            raise AssertionError("Allowed duplicate reversal payment for same original payment!")
        except sqlite3.IntegrityError:
            return "PASS", "Prevented duplicate reversal of same payment"
    test("T18", "Prevent duplicate reversal of same payment", t18)

    # T19_1: Purchase receipt item purchase mismatch rejected
    def t19_1(c, db):
        c.execute("INSERT INTO purchases (id, tenant_id, supplier_id, store_id, order_number, total_amount_centimes, paid_amount, remaining_debt, fulfillment_status, status) VALUES ('PO_19_A', 'TENANT_DEFAULT', 'SUPP_T15', 'STORE_DEFAULT', 'PO-19A', 10000, 0, 10000, 'PENDING', 'ORDERED');")
        c.execute("INSERT INTO purchase_items (id, purchase_id, stock_item_id, quantity_ordered_ticks, unit_cost_ticks, line_total_centimes) VALUES ('PI_19_A', 'PO_19_A', 'SI_T6_A', 100000, 100, 10000);")
        
        c.execute("INSERT INTO purchases (id, tenant_id, supplier_id, store_id, order_number, total_amount_centimes, paid_amount, remaining_debt, fulfillment_status, status) VALUES ('PO_19_B', 'TENANT_DEFAULT', 'SUPP_T15', 'STORE_DEFAULT', 'PO-19B', 5000, 0, 5000, 'PENDING', 'ORDERED');")
        c.execute("INSERT INTO purchase_items (id, purchase_id, stock_item_id, quantity_ordered_ticks, unit_cost_ticks, line_total_centimes) VALUES ('PI_19_B', 'PO_19_B', 'SI_T6_A', 50000, 100, 5000);")
        
        c.execute("INSERT INTO purchase_receipts (id, tenant_id, purchase_id, warehouse_id, receipt_number, status) VALUES ('REC_19', 'TENANT_DEFAULT', 'PO_19_A', 'WH_DEFAULT', 'GRN-19', 'COMPLETED');")
        
        try:
            c.execute("INSERT INTO purchase_receipt_items (id, receipt_id, purchase_item_id, stock_item_id, quantity_received_ticks, unit_cost_ticks) VALUES ('REC_ITEM_ERR', 'REC_19', 'PI_19_B', 'SI_T6_A', 10000, 100);")
            raise AssertionError("Allowed receipt item pointing to different purchase order item!")
        except sqlite3.IntegrityError as e:
            assert 'RECEIPT_ITEM_PURCHASE_ORDER_MISMATCH' in str(e)
            return "PASS", "Aborted with RECEIPT_ITEM_PURCHASE_ORDER_MISMATCH"
    test("T19_1", "Reject purchase receipt item from different purchase order", t19_1)

    # T19_2: Purchase receipt item with matching purchase order but different StockItem
    def t19_2(c, db):
        try:
            c.execute("INSERT INTO purchase_receipt_items (id, receipt_id, purchase_item_id, stock_item_id, quantity_received_ticks, unit_cost_ticks) VALUES ('REC_ITEM_STOCK_MISMATCH', 'REC_19', 'PI_19_A', 'SI_T6_B', 10000, 100);")
            raise AssertionError("Allowed receipt item with mismatched stock item!")
        except sqlite3.IntegrityError as e:
            assert 'RECEIPT_ITEM_STOCK_ITEM_MISMATCH' in str(e)
            return "PASS", "Aborted with RECEIPT_ITEM_STOCK_ITEM_MISMATCH"
    test("T19_2", "Reject purchase receipt item with matching order but different StockItem", t19_2)

    # T20: Over-receipt rejected
    def t20(c, db):
        try:
            c.execute("INSERT INTO purchase_receipt_items (id, receipt_id, purchase_item_id, stock_item_id, quantity_received_ticks, unit_cost_ticks) VALUES ('REC_ITEM_ERR_20', 'REC_19', 'PI_19_A', 'SI_T6_A', 150000, 100);")
            raise AssertionError("Allowed receiving more than ordered!")
        except sqlite3.IntegrityError:
            return "PASS", "Rejected receiving exceeding ordered balance"
    test("T20", "Reject purchase receiving exceeding ordered quantity", t20)

    # T21: Purchase return exceeding received quantity rejected
    def t21(c, db):
        c.execute("INSERT INTO purchase_receipt_items (id, receipt_id, purchase_item_id, stock_item_id, quantity_received_ticks, unit_cost_ticks) VALUES ('REC_ITEM_OK_21', 'REC_19', 'PI_19_A', 'SI_T6_A', 40000, 100);")
        c.execute("INSERT INTO purchase_returns (id, tenant_id, purchase_id, supplier_id, warehouse_id, return_number, total_credit_centimes, status) VALUES ('PRET_21', 'TENANT_DEFAULT', 'PO_19_A', 'SUPP_T15', 'WH_DEFAULT', 'PRTN-21', 5000, 'COMPLETED');")
        try:
            c.execute("INSERT INTO purchase_return_items (id, purchase_return_id, purchase_item_id, stock_item_id, returned_quantity_ticks, unit_cost_ticks, line_total_centimes) VALUES ('PRT_ITEM_ERR', 'PRET_21', 'PI_19_A', 'SI_T6_A', 50000, 100, 5000);")
            raise AssertionError("Allowed purchase return exceeding received quantity!")
        except sqlite3.IntegrityError:
            return "PASS", "Rejected purchase return exceeding received quantity"
    test("T21", "Reject purchase return exceeding received quantity", t21)

    # T22: Multiple open shifts for same cash register rejected
    def t22(c, db):
        c.execute("INSERT INTO users (id, tenant_id, username, password_hash, salt, full_name) VALUES ('U_T22', 'TENANT_DEFAULT', 'user22', 'HASH', 'SALT', 'User 22');")
        c.execute("INSERT INTO cash_registers (id, tenant_id, store_id, name, code) VALUES ('CR_T22', 'TENANT_DEFAULT', 'STORE_DEFAULT', 'Register 22', 'REG-22');")
        c.execute("INSERT INTO cash_shifts (id, cash_register_id, user_id, opening_float_centimes, status) VALUES ('SHIFT_22_1', 'CR_T22', 'U_T22', 1000, 'OPEN');")
        try:
            c.execute("INSERT INTO cash_shifts (id, cash_register_id, user_id, opening_float_centimes, status) VALUES ('SHIFT_22_2', 'CR_T22', 'U_T22', 1000, 'OPEN');")
            raise AssertionError("Allowed opening multiple active shifts for same register!")
        except sqlite3.IntegrityError:
            return "PASS", "Partial UNIQUE index prevented second OPEN shift"
    test("T22", "Prevent multiple open shifts for same cash register", t22)

    # T23: Cash movement duplicate source_event_id
    def t23(c, db):
        c.execute("INSERT INTO cash_movements (id, shift_id, movement_type, amount_centimes, reason, source_event_id) VALUES ('CM_23_1', 'SHIFT_22_1', 'FLOAT_ADD', 500, 'Top up', 'EVT_CM_23');")
        try:
            c.execute("INSERT INTO cash_movements (id, shift_id, movement_type, amount_centimes, reason, source_event_id) VALUES ('CM_23_2', 'SHIFT_22_1', 'FLOAT_ADD', 500, 'Top up dup', 'EVT_CM_23');")
            raise AssertionError("Allowed duplicate cash movement source_event_id!")
        except sqlite3.IntegrityError:
            return "PASS", "Prevented duplicate cash movement source_event_id"
    test("T23", "Prevent duplicate cash movement source_event_id", t23)

    # T24: Variant linked to wrong product rejected
    def t24(c, db):
        c.execute("INSERT INTO products (id, tenant_id, base_unit_id, name, has_variants) VALUES ('P_T24_A', 'TENANT_DEFAULT', 'UOM_PIECE', 'Product 24A', 1);")
        c.execute("INSERT INTO product_variants (id, product_id, sku, variant_name) VALUES ('VAR_24_A', 'P_T24_A', 'SKU-24A', 'Red');")
        c.execute("INSERT INTO products (id, tenant_id, base_unit_id, name, has_variants) VALUES ('P_T24_B', 'TENANT_DEFAULT', 'UOM_PIECE', 'Product 24B', 1);")
        try:
            c.execute("INSERT INTO stock_items (id, product_id, variant_id) VALUES ('SI_MISMATCH', 'P_T24_B', 'VAR_24_A');")
            raise AssertionError("Allowed stock item with mismatched product and variant!")
        except sqlite3.IntegrityError:
            return "PASS", "Aborted variant belonging to different product"
    test("T24", "Reject stock item with variant belonging to different product", t24)

    # T25: Duplicate simple stock item rejected
    def t25(c, db):
        c.execute("INSERT INTO products (id, tenant_id, base_unit_id, name, has_variants) VALUES ('P_T25', 'TENANT_DEFAULT', 'UOM_PIECE', 'Product 25', 1);")
        c.execute("INSERT INTO stock_items (id, product_id, variant_id) VALUES ('SI_25_1', 'P_T25', NULL);")
        try:
            c.execute("INSERT INTO stock_items (id, product_id, variant_id) VALUES ('SI_25_2', 'P_T25', NULL);")
            raise AssertionError("Allowed multiple simple stock items for same product!")
        except sqlite3.IntegrityError:
            return "PASS", "Partial UNIQUE index prevented second simple stock item"
    test("T25", "Enforce exactly one simple stock item per product (partial unique index)", t25)

    # T26: Dimension change protection
    def t26(c, db):
        try:
            c.execute("UPDATE units_of_measure SET dimension='LENGTH' WHERE id='UOM_PIECE';")
            raise AssertionError("Allowed changing dimension of in-use unit of measure!")
        except sqlite3.IntegrityError:
            return "PASS", "Trigger prevented dimension change of in-use unit"
    test("T26", "Protect unit of measure dimension change when in use", t26)

    # T27: Contradictory reverse unit conversion rejected
    def t27(c, db):
        c.execute("INSERT INTO unit_conversions (id, from_unit_id, to_unit_id, factor_numerator, factor_denominator) VALUES ('UC_KG_G', 'UOM_KG', 'UOM_GRAM', 1000, 1);")
        try:
            c.execute("INSERT INTO unit_conversions (id, from_unit_id, to_unit_id, factor_numerator, factor_denominator) VALUES ('UC_G_KG_ERR', 'UOM_GRAM', 'UOM_KG', 1, 1);")
            raise AssertionError("Allowed contradictory reverse unit conversion!")
        except sqlite3.IntegrityError:
            return "PASS", "Trigger prevented contradictory reverse unit conversion"
    test("T27", "Reject contradictory reverse unit conversion", t27)

    # T28: Cross-store linkage rejected
    def t28(c, db):
        c.execute("INSERT INTO stores (id, tenant_id, code, name) VALUES ('STORE_28_B', 'TENANT_DEFAULT', 'ST-28B', 'Branch 28B');")
        c.execute("INSERT INTO warehouses (id, tenant_id, store_id, name) VALUES ('WH_28_B', 'TENANT_DEFAULT', 'STORE_28_B', 'Warehouse 28B');")
        try:
            c.execute("INSERT INTO sales (id, tenant_id, store_id, warehouse_id, device_id, total_amount_centimes, paid_amount, remaining_debt, status) VALUES ('S_CROSS_STORE', 'TENANT_DEFAULT', 'STORE_DEFAULT', 'WH_28_B', 'DEV_T6', 1000, 1000, 0, 'COMPLETED');")
            raise AssertionError("Allowed sale referencing warehouse belonging to a different store!")
        except sqlite3.IntegrityError:
            return "PASS", "Trigger prevented warehouse belonging to another store"
    test("T28", "Enforce store and warehouse alignment", t28)

    # T29: Delete completed sale rejected
    def t29(c, db):
        try:
            c.execute("DELETE FROM sales WHERE id='S_T6';")
            raise AssertionError("Allowed deleting completed sale document!")
        except sqlite3.IntegrityError:
            return "PASS", "Trigger prevented deletion of completed sale"
    test("T29", "Prevent hard deletion of completed sales", t29)

    # T30: Delete draft sale allowed
    def t30(c, db):
        c.execute("INSERT INTO sales (id, tenant_id, store_id, warehouse_id, device_id, total_amount_centimes, paid_amount, remaining_debt, status) VALUES ('S_DRAFT_30', 'TENANT_DEFAULT', 'STORE_DEFAULT', 'WH_DEFAULT', 'DEV_T6', 1000, 0, 1000, 'DRAFT');")
        c.execute("DELETE FROM sales WHERE id='S_DRAFT_30';")
        c.execute("SELECT count(*) FROM sales WHERE id='S_DRAFT_30';")
        assert c.fetchone()[0] == 0
        return "PASS", "Deleted draft sale successfully"
    test("T30", "Allow deletion of unapproved DRAFT sales", t30)

    # T31 & T32: Idempotency replay returns cached result & rejects key reuse with different hash
    def t31_32(c, db):
        c.execute("INSERT INTO idempotency_records (id, tenant_id, device_id, client_request_id, endpoint, request_hash, response_code, response_payload_json) VALUES ('IDEM_1', 'TENANT_DEFAULT', 'DEV_T6', 'REQ_UUID_100', '/api/v1/sales', 'HASH_ABC', 200, '{\"status\":\"OK\"}');")
        c.execute("SELECT response_payload_json FROM idempotency_records WHERE tenant_id='TENANT_DEFAULT' AND device_id='DEV_T6' AND client_request_id='REQ_UUID_100' AND request_hash='HASH_ABC';")
        cached = c.fetchone()
        assert cached is not None and cached[0] == '{\"status\":\"OK\"}'
        try:
            c.execute("INSERT INTO idempotency_records (id, tenant_id, device_id, client_request_id, endpoint, request_hash, response_code, response_payload_json) VALUES ('IDEM_2', 'TENANT_DEFAULT', 'DEV_T6', 'REQ_UUID_100', '/api/v1/sales', 'DIFFERENT_HASH', 200, '{}');")
            raise AssertionError("Allowed duplicate client_request_id with different payload!")
        except sqlite3.IntegrityError:
            return "PASS", "Replay returned cached response and rejected key reuse"
    test("T31_32", "Idempotency replay returns cached result & rejects key reuse with different hash", t31_32)

    # T33: Audit logs immutability
    def t33(c, db):
        c.execute("INSERT INTO audit_logs (id, tenant_id, action, entity_name, entity_id) VALUES ('AUD_1', 'TENANT_DEFAULT', 'CREATE', 'PRODUCT', 'P_1');")
        try:
            c.execute("UPDATE audit_logs SET action='MODIFIED' WHERE id='AUD_1';")
            raise AssertionError("Allowed updating audit_logs!")
        except sqlite3.IntegrityError:
            pass
        try:
            c.execute("DELETE FROM audit_logs WHERE id='AUD_1';")
            raise AssertionError("Allowed deleting audit_logs!")
        except sqlite3.IntegrityError:
            pass
        return "PASS", "Audit logs rejected both UPDATE and DELETE"
    test("T33", "Enforce audit_logs immutability (no update/no delete)", t33)

    # T34: Product creation with name only auto-provisions StockItem and Balance
    def t34(c, db):
        c.execute("INSERT INTO products (id, tenant_id, name) VALUES ('P_SIMPLE_AUTO', 'TENANT_DEFAULT', 'زيت زيتون بكر');")
        
        # 1. Check base_unit_id defaulted to UOM_PIECE
        c.execute("SELECT base_unit_id, track_inventory, is_active FROM products WHERE id='P_SIMPLE_AUTO';")
        p_row = c.fetchone()
        assert p_row[0] == 'UOM_PIECE', f"Expected default UOM_PIECE, got {p_row[0]}"
        
        # 2. Check stock_items row was automatically provisioned
        c.execute("SELECT id, variant_id FROM stock_items WHERE product_id='P_SIMPLE_AUTO';")
        si_row = c.fetchone()
        assert si_row is not None, "Stock item was not automatically provisioned!"
        assert si_row[0] == 'SI_P_SIMPLE_AUTO', f"Expected SI_P_SIMPLE_AUTO, got {si_row[0]}"
        assert si_row[1] is None, "Expected variant_id to be NULL for simple product"
        
        # 3. Check inventory_balances row was automatically provisioned in default warehouse
        c.execute("SELECT on_hand_ticks, reserved_ticks, current_moving_avg_cost FROM inventory_balances WHERE warehouse_id='WH_DEFAULT' AND stock_item_id='SI_P_SIMPLE_AUTO';")
        bal_row = c.fetchone()
        assert bal_row is not None, "Inventory balance was not automatically provisioned in default warehouse!"
        assert bal_row[0] == 0 and bal_row[1] == 0 and bal_row[2] == 0, f"Expected 0/0/0 ticks, got {bal_row}"
        
        return "PASS", "Auto-provisioned product, StockItem (SI_P_SIMPLE_AUTO), and initial balance (0/0/0)"
    test("T34", "Product creation by name only auto-provisions StockItem and Balance", t34)

    conn.close()

    pass_count = sum(1 for status, _, _ in results.values() if status == "PASS")
    fail_count = sum(1 for status, _, _ in results.values() if status == "FAIL")
    not_run_count = sum(1 for status, _, _ in results.values() if status == "NOT RUN")
    
    print(f"\n==========================================")
    print(f"VERIFICATION SUMMARY: {pass_count} PASSED, {fail_count} FAILED, {not_run_count} NOT RUN (out of {len(results)} tests)")
    print(f"==========================================")
    if fail_count > 0:
        sys.exit(1)

if __name__ == "__main__":
    run_tests()
