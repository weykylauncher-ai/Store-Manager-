-- ====================================================================
-- Store Manager Pro: Canonical Database Schema DDL (55 Tables)
-- Engine: SQLite 3.40.1+ / SQLDelight
-- Master Fresh Production Baseline v1.0
-- ====================================================================

PRAGMA foreign_keys = ON;

-- --------------------------------------------------------------------
-- 1. Core Tenants, Stores, Currencies & System Configuration
-- --------------------------------------------------------------------
CREATE TABLE tenants (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    is_active INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE stores (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    code TEXT NOT NULL,
    name TEXT NOT NULL,
    address TEXT,
    phone TEXT,
    is_active INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    UNIQUE(tenant_id, code)
);

CREATE TABLE fiscal_years (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    year INTEGER NOT NULL,
    start_date TEXT NOT NULL,
    end_date TEXT NOT NULL,
    is_closed INTEGER NOT NULL DEFAULT 0,
    UNIQUE(tenant_id, year)
);

CREATE TABLE currencies (
    code TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    symbol TEXT NOT NULL,
    decimal_places INTEGER NOT NULL DEFAULT 2,
    is_base INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE exchange_rates (
    id TEXT PRIMARY KEY,
    currency_code TEXT NOT NULL REFERENCES currencies(code) ON DELETE RESTRICT,
    rate_numerator INTEGER NOT NULL,
    rate_denominator INTEGER NOT NULL,
    valid_from TEXT NOT NULL,
    CHECK(rate_numerator > 0 AND rate_denominator > 0)
);

CREATE TABLE app_licenses (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    license_key TEXT NOT NULL UNIQUE,
    licensee_name TEXT NOT NULL,
    machine_fingerprint TEXT NOT NULL,
    issued_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    grace_period_days INTEGER NOT NULL DEFAULT 14,
    features_payload_json TEXT NOT NULL,
    digital_signature TEXT NOT NULL,
    status TEXT NOT NULL CHECK(status IN ('ACTIVE', 'GRACE_PERIOD', 'EXPIRED', 'REVOKED'))
);

CREATE TABLE document_sequences (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    store_id TEXT NOT NULL REFERENCES stores(id) ON DELETE RESTRICT,
    fiscal_year INTEGER NOT NULL,
    document_type TEXT NOT NULL CHECK(document_type IN ('SALE', 'SALE_RETURN', 'PURCHASE', 'PURCHASE_RECEIPT', 'PURCHASE_RETURN', 'PAYMENT', 'ADJUSTMENT')),
    last_sequence_number INTEGER NOT NULL DEFAULT 0,
    prefix TEXT NOT NULL,
    suffix TEXT,
    padding INTEGER NOT NULL DEFAULT 6,
    UNIQUE(tenant_id, store_id, fiscal_year, document_type)
);

CREATE TABLE idempotency_records (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    device_id TEXT NOT NULL,
    client_request_id TEXT NOT NULL,
    endpoint TEXT NOT NULL,
    request_hash TEXT NOT NULL,
    response_code INTEGER,
    response_payload_json TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    UNIQUE(tenant_id, device_id, client_request_id)
);

CREATE TABLE backup_history (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    backup_type TEXT NOT NULL CHECK(backup_type IN ('AUTOMATIC', 'MANUAL_EXPORT', 'BEFORE_UPGRADE')),
    file_path TEXT NOT NULL,
    file_size_bytes INTEGER NOT NULL,
    sha256_checksum TEXT NOT NULL,
    status TEXT NOT NULL CHECK(status IN ('SUCCESS', 'FAILED', 'VERIFIED')),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    restored_at TEXT
);

-- --------------------------------------------------------------------
-- 2. Identity, Access Control & Devices
-- --------------------------------------------------------------------
CREATE TABLE users (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    username TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    salt TEXT NOT NULL,
    full_name TEXT NOT NULL,
    is_active INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    UNIQUE(tenant_id, username)
);

CREATE TABLE roles (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    name TEXT NOT NULL,
    description TEXT,
    is_system INTEGER NOT NULL DEFAULT 0,
    UNIQUE(tenant_id, name)
);

CREATE TABLE permissions (
    code TEXT PRIMARY KEY,
    category TEXT NOT NULL,
    description TEXT NOT NULL
);

CREATE TABLE role_permissions (
    role_id TEXT NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    permission_code TEXT NOT NULL REFERENCES permissions(code) ON DELETE CASCADE,
    PRIMARY KEY(role_id, permission_code)
);

CREATE TABLE user_roles (
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role_id TEXT NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    PRIMARY KEY(user_id, role_id)
);

CREATE TABLE user_sessions (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL UNIQUE,
    ip_address TEXT,
    device_info TEXT,
    expires_at TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE registered_devices (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    store_id TEXT NOT NULL REFERENCES stores(id) ON DELETE RESTRICT,
    device_name TEXT NOT NULL,
    device_type TEXT NOT NULL CHECK(device_type IN ('ANDROID_POS', 'WINDOWS_WORKSTATION')),
    public_key TEXT NOT NULL UNIQUE,
    pairing_status TEXT NOT NULL CHECK(pairing_status IN ('PENDING', 'ACTIVE', 'REVOKED', 'SUSPENDED')),
    last_seq_num INTEGER NOT NULL DEFAULT 0,
    last_seen_at TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE device_pairing_pins (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    pin_hmac TEXT NOT NULL,
    salt TEXT NOT NULL,
    attempts_remaining INTEGER NOT NULL DEFAULT 3,
    expires_at TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE audit_logs (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
    action TEXT NOT NULL,
    entity_name TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    payload_before TEXT,
    payload_after TEXT,
    ip_address TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

-- --------------------------------------------------------------------
-- 3. Product Catalog, Variants, Units & Pricing
-- --------------------------------------------------------------------
CREATE TABLE categories (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    parent_id TEXT REFERENCES categories(id) ON DELETE RESTRICT,
    name TEXT NOT NULL,
    code TEXT,
    is_active INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE tax_rates (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    name TEXT NOT NULL,
    rate_bps INTEGER NOT NULL CHECK(rate_bps >= 0 AND rate_bps <= 10000),
    is_active INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE units_of_measure (
    id TEXT PRIMARY KEY,
    dimension TEXT NOT NULL CHECK(dimension IN ('COUNT', 'WEIGHT', 'VOLUME', 'LENGTH', 'AREA')),
    name_ar TEXT NOT NULL,
    name_fr TEXT NOT NULL,
    symbol TEXT NOT NULL,
    is_fractional INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE unit_conversions (
    id TEXT PRIMARY KEY,
    from_unit_id TEXT NOT NULL REFERENCES units_of_measure(id) ON DELETE RESTRICT,
    to_unit_id TEXT NOT NULL REFERENCES units_of_measure(id) ON DELETE RESTRICT,
    factor_numerator INTEGER NOT NULL CHECK(factor_numerator > 0),
    factor_denominator INTEGER NOT NULL CHECK(factor_denominator > 0),
    UNIQUE(from_unit_id, to_unit_id)
);

CREATE TABLE products (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    category_id TEXT REFERENCES categories(id) ON DELETE SET NULL,
    base_unit_id TEXT NOT NULL DEFAULT 'UOM_PIECE' REFERENCES units_of_measure(id) ON DELETE RESTRICT,
    name TEXT NOT NULL,
    code TEXT,
    barcode TEXT,
    track_inventory INTEGER NOT NULL DEFAULT 1,
    has_variants INTEGER NOT NULL DEFAULT 0,
    is_active INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE product_variants (
    id TEXT PRIMARY KEY,
    product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    sku TEXT NOT NULL UNIQUE,
    barcode TEXT,
    variant_name TEXT NOT NULL,
    attributes_json TEXT,
    is_active INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE price_lists (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    name TEXT NOT NULL,
    currency_code TEXT NOT NULL REFERENCES currencies(code) ON DELETE RESTRICT,
    is_default INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE price_list_items (
    id TEXT PRIMARY KEY,
    price_list_id TEXT NOT NULL REFERENCES price_lists(id) ON DELETE CASCADE,
    product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    variant_id TEXT REFERENCES product_variants(id) ON DELETE CASCADE,
    unit_price_ticks INTEGER NOT NULL CHECK(unit_price_ticks >= 0),
    UNIQUE(price_list_id, product_id, variant_id)
);

-- --------------------------------------------------------------------
-- 4. Parties & Party Ledger
-- --------------------------------------------------------------------
CREATE TABLE customer_groups (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    name TEXT NOT NULL,
    discount_bps INTEGER NOT NULL DEFAULT 0 CHECK(discount_bps >= 0 AND discount_bps <= 10000)
);

CREATE TABLE customers (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    group_id TEXT REFERENCES customer_groups(id) ON DELETE SET NULL,
    name TEXT NOT NULL,
    phone TEXT,
    email TEXT,
    credit_limit_centimes INTEGER NOT NULL DEFAULT 0,
    current_balance_centimes INTEGER NOT NULL DEFAULT 0,
    is_active INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE suppliers (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    name TEXT NOT NULL,
    contact_name TEXT,
    phone TEXT,
    current_balance_centimes INTEGER NOT NULL DEFAULT 0,
    is_active INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE party_ledger_entries (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    party_type TEXT NOT NULL CHECK(party_type IN ('CUSTOMER', 'SUPPLIER')),
    party_id TEXT NOT NULL,
    source_document_type TEXT NOT NULL CHECK(source_document_type IN ('SALE', 'SALE_RETURN', 'PURCHASE', 'PURCHASE_RETURN', 'PAYMENT', 'ADJUSTMENT')),
    source_document_id TEXT NOT NULL,
    debit_centimes INTEGER NOT NULL DEFAULT 0 CHECK(debit_centimes >= 0),
    credit_centimes INTEGER NOT NULL DEFAULT 0 CHECK(credit_centimes >= 0),
    running_balance_centimes INTEGER NOT NULL,
    notes TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

-- --------------------------------------------------------------------
-- 5. Warehouses, Stock Items, Movements, Adjustments & Quotas
-- --------------------------------------------------------------------
CREATE TABLE warehouses (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    store_id TEXT NOT NULL REFERENCES stores(id) ON DELETE RESTRICT,
    name TEXT NOT NULL,
    is_default INTEGER NOT NULL DEFAULT 0,
    is_active INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE stock_items (
    id TEXT PRIMARY KEY,
    product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    variant_id TEXT REFERENCES product_variants(id) ON DELETE CASCADE,
    UNIQUE(product_id, variant_id)
);

CREATE UNIQUE INDEX idx_stock_items_simple_product 
ON stock_items(product_id) 
WHERE variant_id IS NULL;

CREATE TABLE inventory_balances (
    warehouse_id TEXT NOT NULL REFERENCES warehouses(id) ON DELETE RESTRICT,
    stock_item_id TEXT NOT NULL REFERENCES stock_items(id) ON DELETE RESTRICT,
    on_hand_ticks INTEGER NOT NULL DEFAULT 0 CHECK(on_hand_ticks >= 0),
    reserved_ticks INTEGER NOT NULL DEFAULT 0 CHECK(reserved_ticks >= 0),
    current_moving_avg_cost INTEGER NOT NULL DEFAULT 0 CHECK(current_moving_avg_cost >= 0),
    PRIMARY KEY(warehouse_id, stock_item_id),
    CHECK(on_hand_ticks >= reserved_ticks)
);

CREATE TABLE inventory_movements (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    warehouse_id TEXT NOT NULL REFERENCES warehouses(id) ON DELETE RESTRICT,
    stock_item_id TEXT NOT NULL REFERENCES stock_items(id) ON DELETE RESTRICT,
    movement_type TEXT NOT NULL CHECK(movement_type IN ('PURCHASE_RECEIPT', 'SALE_SHIPMENT', 'SALE_RETURN', 'PURCHASE_RETURN', 'ADJUSTMENT_IN', 'ADJUSTMENT_OUT', 'TRANSFER_IN', 'TRANSFER_OUT')),
    source_event_id TEXT UNIQUE NOT NULL,
    reference_line_id TEXT,
    quantity_ticks INTEGER NOT NULL,
    unit_cost_ticks INTEGER NOT NULL DEFAULT 0,
    total_cost_centimes INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE inventory_adjustments (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    warehouse_id TEXT NOT NULL REFERENCES warehouses(id) ON DELETE RESTRICT,
    adjustment_number TEXT NOT NULL UNIQUE,
    reason TEXT NOT NULL,
    status TEXT NOT NULL CHECK(status IN ('DRAFT', 'POSTED', 'CANCELLED')),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE inventory_adjustment_lines (
    id TEXT PRIMARY KEY,
    adjustment_id TEXT NOT NULL REFERENCES inventory_adjustments(id) ON DELETE CASCADE,
    stock_item_id TEXT NOT NULL REFERENCES stock_items(id) ON DELETE RESTRICT,
    system_quantity_ticks INTEGER NOT NULL,
    actual_quantity_ticks INTEGER NOT NULL,
    difference_ticks INTEGER NOT NULL,
    unit_cost_ticks INTEGER NOT NULL
);

CREATE TABLE inventory_quotas (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    device_id TEXT NOT NULL REFERENCES registered_devices(id) ON DELETE RESTRICT,
    warehouse_id TEXT NOT NULL REFERENCES warehouses(id) ON DELETE RESTRICT,
    stock_item_id TEXT NOT NULL REFERENCES stock_items(id) ON DELETE RESTRICT,
    quota_quantity_ticks INTEGER NOT NULL CHECK(quota_quantity_ticks > 0),
    consumed_quantity_ticks INTEGER NOT NULL DEFAULT 0 CHECK(consumed_quantity_ticks >= 0),
    valid_until TEXT NOT NULL,
    status TEXT NOT NULL CHECK(status IN ('ACTIVE', 'RECONCILED', 'EXPIRED', 'LOST_DEVICE_EXPOSURE', 'VOIDED_BY_ADMIN')),
    signed_token TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    CHECK(consumed_quantity_ticks <= quota_quantity_ticks)
);

-- --------------------------------------------------------------------
-- 6. Sales, Items, Quota Link & Returns
-- --------------------------------------------------------------------
CREATE TABLE sales (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    store_id TEXT NOT NULL REFERENCES stores(id) ON DELETE RESTRICT,
    warehouse_id TEXT NOT NULL REFERENCES warehouses(id) ON DELETE RESTRICT,
    customer_id TEXT REFERENCES customers(id) ON DELETE RESTRICT,
    device_id TEXT NOT NULL REFERENCES registered_devices(id) ON DELETE RESTRICT,
    invoice_number TEXT UNIQUE,
    offline_receipt_number TEXT,
    local_operation_uuid TEXT,
    device_seq_num INTEGER,
    device_signature TEXT,
    request_hash TEXT,
    batch_id TEXT,
    subtotal_centimes INTEGER NOT NULL DEFAULT 0 CHECK(subtotal_centimes >= 0),
    discount_centimes INTEGER NOT NULL DEFAULT 0 CHECK(discount_centimes >= 0),
    tax_centimes INTEGER NOT NULL DEFAULT 0 CHECK(tax_centimes >= 0),
    total_amount_centimes INTEGER NOT NULL CHECK(total_amount_centimes >= 0),
    paid_amount INTEGER NOT NULL DEFAULT 0 CHECK(paid_amount >= 0),
    remaining_debt INTEGER NOT NULL CHECK(remaining_debt >= 0),
    status TEXT NOT NULL CHECK(status IN ('DRAFT', 'COMPLETED', 'CANCELLED')),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    UNIQUE(device_id, local_operation_uuid),
    CHECK(paid_amount + remaining_debt = total_amount_centimes)
);

CREATE TABLE sale_items (
    id TEXT PRIMARY KEY,
    sale_id TEXT NOT NULL REFERENCES sales(id) ON DELETE CASCADE,
    stock_item_id TEXT NOT NULL REFERENCES stock_items(id) ON DELETE RESTRICT,
    quantity_ticks INTEGER NOT NULL CHECK(quantity_ticks > 0),
    returned_quantity_ticks INTEGER NOT NULL DEFAULT 0 CHECK(returned_quantity_ticks >= 0),
    unit_price_ticks INTEGER NOT NULL CHECK(unit_price_ticks >= 0),
    discount_bps INTEGER NOT NULL DEFAULT 0 CHECK(discount_bps >= 0 AND discount_bps <= 10000),
    tax_bps INTEGER NOT NULL DEFAULT 0 CHECK(tax_bps >= 0 AND tax_bps <= 10000),
    line_total_centimes INTEGER NOT NULL CHECK(line_total_centimes >= 0),
    cost_at_sale_ticks INTEGER NOT NULL DEFAULT 0,
    CHECK(returned_quantity_ticks <= quantity_ticks)
);

CREATE TABLE sale_item_quota_deductions (
    id TEXT PRIMARY KEY,
    sale_item_id TEXT NOT NULL REFERENCES sale_items(id) ON DELETE CASCADE,
    quota_id TEXT NOT NULL REFERENCES inventory_quotas(id) ON DELETE RESTRICT,
    deducted_quantity_ticks INTEGER NOT NULL CHECK(deducted_quantity_ticks > 0),
    UNIQUE(sale_item_id, quota_id)
);

CREATE TABLE sale_returns (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    store_id TEXT NOT NULL REFERENCES stores(id) ON DELETE RESTRICT,
    warehouse_id TEXT NOT NULL REFERENCES warehouses(id) ON DELETE RESTRICT,
    original_sale_id TEXT NOT NULL REFERENCES sales(id) ON DELETE RESTRICT,
    return_number TEXT UNIQUE NOT NULL,
    customer_id TEXT REFERENCES customers(id) ON DELETE RESTRICT,
    total_refund_centimes INTEGER NOT NULL CHECK(total_refund_centimes >= 0),
    refund_status TEXT NOT NULL CHECK(refund_status IN ('PENDING', 'REFUNDED_CASH', 'CREDITED_TO_ACCOUNT')),
    status TEXT NOT NULL CHECK(status IN ('COMPLETED', 'CANCELLED')),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE sale_return_items (
    id TEXT PRIMARY KEY,
    return_id TEXT NOT NULL REFERENCES sale_returns(id) ON DELETE CASCADE,
    original_sale_item_id TEXT NOT NULL REFERENCES sale_items(id) ON DELETE RESTRICT,
    stock_item_id TEXT NOT NULL REFERENCES stock_items(id) ON DELETE RESTRICT,
    returned_quantity_ticks INTEGER NOT NULL CHECK(returned_quantity_ticks > 0),
    refund_unit_price_ticks INTEGER NOT NULL CHECK(refund_unit_price_ticks >= 0),
    line_total_centimes INTEGER NOT NULL CHECK(line_total_centimes >= 0)
);

-- --------------------------------------------------------------------
-- 7. Purchases, Partial Receipts & Supplier Returns
-- --------------------------------------------------------------------
CREATE TABLE purchases (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    supplier_id TEXT NOT NULL REFERENCES suppliers(id) ON DELETE RESTRICT,
    store_id TEXT NOT NULL REFERENCES stores(id) ON DELETE RESTRICT,
    order_number TEXT UNIQUE NOT NULL,
    total_amount_centimes INTEGER NOT NULL CHECK(total_amount_centimes >= 0),
    paid_amount INTEGER NOT NULL DEFAULT 0 CHECK(paid_amount >= 0),
    remaining_debt INTEGER NOT NULL CHECK(remaining_debt >= 0),
    fulfillment_status TEXT NOT NULL CHECK(fulfillment_status IN ('PENDING', 'PARTIALLY_RECEIVED', 'FULLY_RECEIVED')),
    status TEXT NOT NULL CHECK(status IN ('DRAFT', 'ORDERED', 'RECEIVED', 'CANCELLED')),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    CHECK(paid_amount + remaining_debt = total_amount_centimes)
);

CREATE TABLE purchase_items (
    id TEXT PRIMARY KEY,
    purchase_id TEXT NOT NULL REFERENCES purchases(id) ON DELETE CASCADE,
    stock_item_id TEXT NOT NULL REFERENCES stock_items(id) ON DELETE RESTRICT,
    quantity_ordered_ticks INTEGER NOT NULL CHECK(quantity_ordered_ticks > 0),
    quantity_received_ticks INTEGER NOT NULL DEFAULT 0 CHECK(quantity_received_ticks >= 0),
    quantity_returned_ticks INTEGER NOT NULL DEFAULT 0 CHECK(quantity_returned_ticks >= 0),
    unit_cost_ticks INTEGER NOT NULL CHECK(unit_cost_ticks >= 0),
    line_total_centimes INTEGER NOT NULL CHECK(line_total_centimes >= 0),
    CHECK(quantity_received_ticks <= quantity_ordered_ticks),
    CHECK(quantity_returned_ticks <= quantity_received_ticks)
);

CREATE TABLE purchase_receipts (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    purchase_id TEXT NOT NULL REFERENCES purchases(id) ON DELETE RESTRICT,
    warehouse_id TEXT NOT NULL REFERENCES warehouses(id) ON DELETE RESTRICT,
    receipt_number TEXT UNIQUE NOT NULL,
    received_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    status TEXT NOT NULL CHECK(status IN ('COMPLETED', 'CANCELLED'))
);

CREATE TABLE purchase_receipt_items (
    id TEXT PRIMARY KEY,
    receipt_id TEXT NOT NULL REFERENCES purchase_receipts(id) ON DELETE CASCADE,
    purchase_item_id TEXT NOT NULL REFERENCES purchase_items(id) ON DELETE RESTRICT,
    stock_item_id TEXT NOT NULL REFERENCES stock_items(id) ON DELETE RESTRICT,
    quantity_received_ticks INTEGER NOT NULL CHECK(quantity_received_ticks > 0),
    unit_cost_ticks INTEGER NOT NULL CHECK(unit_cost_ticks >= 0)
);

CREATE TABLE purchase_returns (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    purchase_id TEXT NOT NULL REFERENCES purchases(id) ON DELETE RESTRICT,
    supplier_id TEXT NOT NULL REFERENCES suppliers(id) ON DELETE RESTRICT,
    warehouse_id TEXT NOT NULL REFERENCES warehouses(id) ON DELETE RESTRICT,
    return_number TEXT UNIQUE NOT NULL,
    total_credit_centimes INTEGER NOT NULL CHECK(total_credit_centimes >= 0),
    status TEXT NOT NULL CHECK(status IN ('COMPLETED', 'CANCELLED')),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE purchase_return_items (
    id TEXT PRIMARY KEY,
    purchase_return_id TEXT NOT NULL REFERENCES purchase_returns(id) ON DELETE CASCADE,
    purchase_item_id TEXT NOT NULL REFERENCES purchase_items(id) ON DELETE RESTRICT,
    stock_item_id TEXT NOT NULL REFERENCES stock_items(id) ON DELETE RESTRICT,
    returned_quantity_ticks INTEGER NOT NULL CHECK(returned_quantity_ticks > 0),
    unit_cost_ticks INTEGER NOT NULL CHECK(unit_cost_ticks >= 0),
    line_total_centimes INTEGER NOT NULL CHECK(line_total_centimes >= 0)
);

-- --------------------------------------------------------------------
-- 8. Cash Registers, Shifts, Cash Movements & Expenses
-- --------------------------------------------------------------------
CREATE TABLE cash_registers (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    store_id TEXT NOT NULL REFERENCES stores(id) ON DELETE RESTRICT,
    name TEXT NOT NULL,
    code TEXT NOT NULL,
    is_active INTEGER NOT NULL DEFAULT 1,
    UNIQUE(store_id, code)
);

CREATE TABLE cash_shifts (
    id TEXT PRIMARY KEY,
    cash_register_id TEXT NOT NULL REFERENCES cash_registers(id) ON DELETE RESTRICT,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    opened_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    closed_at TEXT,
    opening_float_centimes INTEGER NOT NULL CHECK(opening_float_centimes >= 0),
    expected_cash_centimes INTEGER NOT NULL DEFAULT 0,
    actual_cash_centimes INTEGER,
    difference_centimes INTEGER,
    status TEXT NOT NULL CHECK(status IN ('OPEN', 'CLOSED'))
);

CREATE UNIQUE INDEX idx_one_open_shift_per_register 
ON cash_shifts(cash_register_id) 
WHERE status = 'OPEN';

CREATE TABLE cash_movements (
    id TEXT PRIMARY KEY,
    shift_id TEXT NOT NULL REFERENCES cash_shifts(id) ON DELETE RESTRICT,
    movement_type TEXT NOT NULL CHECK(movement_type IN ('FLOAT_ADD', 'DROP_PAYOUT', 'PETTY_EXPENSE', 'MANUAL_IN', 'MANUAL_OUT')),
    amount_centimes INTEGER NOT NULL CHECK(amount_centimes > 0),
    reason TEXT NOT NULL,
    source_event_id TEXT UNIQUE NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE expense_categories (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    name TEXT NOT NULL,
    is_active INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE expenses (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    store_id TEXT NOT NULL REFERENCES stores(id) ON DELETE RESTRICT,
    category_id TEXT NOT NULL REFERENCES expense_categories(id) ON DELETE RESTRICT,
    amount_centimes INTEGER NOT NULL CHECK(amount_centimes > 0),
    description TEXT NOT NULL,
    shift_id TEXT REFERENCES cash_shifts(id) ON DELETE SET NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

-- --------------------------------------------------------------------
-- 9. Payments, Allocations & Debt Reconciliation
-- --------------------------------------------------------------------
CREATE TABLE payments (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    store_id TEXT NOT NULL REFERENCES stores(id) ON DELETE RESTRICT,
    party_type TEXT NOT NULL CHECK(party_type IN ('CUSTOMER', 'SUPPLIER')),
    party_id TEXT NOT NULL,
    payment_method TEXT NOT NULL CHECK(payment_method IN ('CASH', 'BANK_TRANSFER', 'CHECK', 'CARD')),
    shift_id TEXT REFERENCES cash_shifts(id) ON DELETE SET NULL,
    amount INTEGER NOT NULL CHECK(amount > 0),
    payment_date TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    notes TEXT,
    is_reversal INTEGER NOT NULL DEFAULT 0,
    reversal_of_id TEXT REFERENCES payments(id) ON DELETE RESTRICT,
    UNIQUE(reversal_of_id)
);

CREATE TABLE payment_allocations (
    id TEXT PRIMARY KEY,
    payment_id TEXT NOT NULL REFERENCES payments(id) ON DELETE RESTRICT,
    sale_id TEXT REFERENCES sales(id) ON DELETE RESTRICT,
    purchase_id TEXT REFERENCES purchases(id) ON DELETE RESTRICT,
    allocated_amount INTEGER NOT NULL,
    allocated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    CHECK((sale_id IS NOT NULL AND purchase_id IS NULL) OR (sale_id IS NULL AND purchase_id IS NOT NULL))
);

-- --------------------------------------------------------------------
-- 10. Triggers: Financial, Physical, Operational & Security Invariants
-- --------------------------------------------------------------------

-- Audit Logs Immutability
CREATE TRIGGER trg_audit_logs_no_update
BEFORE UPDATE ON audit_logs
BEGIN
    SELECT RAISE(ABORT, 'AUDIT_LOGS_ARE_IMMUTABLE');
END;

CREATE TRIGGER trg_audit_logs_no_delete
BEFORE DELETE ON audit_logs
BEGIN
    SELECT RAISE(ABORT, 'AUDIT_LOGS_ARE_IMMUTABLE');
END;

-- Document Deletion Protection
CREATE TRIGGER trg_sales_prevent_delete_completed
BEFORE DELETE ON sales
WHEN OLD.status != 'DRAFT'
BEGIN
    SELECT RAISE(ABORT, 'CANNOT_DELETE_APPROVED_OR_COMPLETED_SALE');
END;

CREATE TRIGGER trg_purchases_prevent_delete_completed
BEFORE DELETE ON purchases
WHEN OLD.status != 'DRAFT'
BEGIN
    SELECT RAISE(ABORT, 'CANNOT_DELETE_APPROVED_OR_COMPLETED_PURCHASE');
END;

CREATE TRIGGER trg_inventory_movements_prevent_delete
BEFORE DELETE ON inventory_movements
BEGIN
    SELECT RAISE(ABORT, 'CANNOT_DELETE_HISTORICAL_INVENTORY_MOVEMENTS');
END;

-- Unit of Measure Protection
CREATE TRIGGER trg_protect_seed_uom_delete
BEFORE DELETE ON units_of_measure
WHEN OLD.id = 'UOM_PIECE'
BEGIN
    SELECT RAISE(ABORT, 'SYSTEM_UNIT_OF_MEASURE_CANNOT_BE_DELETED');
END;

CREATE TRIGGER trg_uom_prevent_dimension_update_if_used
BEFORE UPDATE OF dimension ON units_of_measure
WHEN EXISTS (SELECT 1 FROM products WHERE base_unit_id = OLD.id) 
  OR EXISTS (SELECT 1 FROM unit_conversions WHERE from_unit_id = OLD.id OR to_unit_id = OLD.id)
BEGIN
    SELECT RAISE(ABORT, 'CANNOT_MODIFY_DIMENSION_OF_IN_USE_UNIT_OF_MEASURE');
END;

CREATE TRIGGER trg_check_unit_conversion_dimension_insert
BEFORE INSERT ON unit_conversions
BEGIN
    SELECT CASE
        WHEN (SELECT dimension FROM units_of_measure WHERE id = NEW.from_unit_id) !=
             (SELECT dimension FROM units_of_measure WHERE id = NEW.to_unit_id)
        THEN RAISE(ABORT, 'CROSS_DIMENSION_CONVERSION_FORBIDDEN')
        WHEN NEW.from_unit_id = NEW.to_unit_id
        THEN RAISE(ABORT, 'SELF_UNIT_CONVERSION_FORBIDDEN')
        WHEN EXISTS (
            SELECT 1 FROM unit_conversions 
            WHERE from_unit_id = NEW.to_unit_id AND to_unit_id = NEW.from_unit_id
              AND (factor_numerator * NEW.factor_numerator != factor_denominator * NEW.factor_denominator)
        )
        THEN RAISE(ABORT, 'CONTRADICTORY_REVERSE_CONVERSION_FORBIDDEN')
    END;
END;

CREATE TRIGGER trg_check_unit_conversion_dimension_update
BEFORE UPDATE OF from_unit_id, to_unit_id, factor_numerator, factor_denominator ON unit_conversions
BEGIN
    SELECT CASE
        WHEN (SELECT dimension FROM units_of_measure WHERE id = NEW.from_unit_id) !=
             (SELECT dimension FROM units_of_measure WHERE id = NEW.to_unit_id)
        THEN RAISE(ABORT, 'CROSS_DIMENSION_CONVERSION_FORBIDDEN')
        WHEN NEW.from_unit_id = NEW.to_unit_id
        THEN RAISE(ABORT, 'SELF_UNIT_CONVERSION_FORBIDDEN')
        WHEN EXISTS (
            SELECT 1 FROM unit_conversions 
            WHERE from_unit_id = NEW.to_unit_id AND to_unit_id = NEW.from_unit_id
              AND id != OLD.id
              AND (factor_numerator * NEW.factor_numerator != factor_denominator * NEW.factor_denominator)
        )
        THEN RAISE(ABORT, 'CONTRADICTORY_REVERSE_CONVERSION_FORBIDDEN')
    END;
END;

-- Auto-provision StockItem and Initial Balance for Simple Products
CREATE TRIGGER trg_products_auto_create_stock_item_and_balance
AFTER INSERT ON products
WHEN NEW.has_variants = 0
BEGIN
    INSERT INTO stock_items (id, product_id, variant_id)
    VALUES ('SI_' || NEW.id, NEW.id, NULL);

    INSERT INTO inventory_balances (warehouse_id, stock_item_id, on_hand_ticks, reserved_ticks, current_moving_avg_cost)
    SELECT w.id, 'SI_' || NEW.id, 0, 0, 0
    FROM warehouses w
    WHERE w.tenant_id = NEW.tenant_id AND w.is_default = 1;
END;

-- StockItem Product-Variant Consistency Guard
CREATE TRIGGER trg_stock_item_variant_consistency_insert
BEFORE INSERT ON stock_items
WHEN NEW.variant_id IS NOT NULL
BEGIN
    SELECT CASE
        WHEN (SELECT product_id FROM product_variants WHERE id = NEW.variant_id) != NEW.product_id
        THEN RAISE(ABORT, 'VARIANT_DOES_NOT_BELONG_TO_SPECIFIED_PRODUCT')
    END;
END;

CREATE TRIGGER trg_stock_item_variant_consistency_update
BEFORE UPDATE OF product_id, variant_id ON stock_items
WHEN NEW.variant_id IS NOT NULL
BEGIN
    SELECT CASE
        WHEN (SELECT product_id FROM product_variants WHERE id = NEW.variant_id) != NEW.product_id
        THEN RAISE(ABORT, 'VARIANT_DOES_NOT_BELONG_TO_SPECIFIED_PRODUCT')
    END;
END;

-- Tenant & Store Alignment Trigger on Sales
CREATE TRIGGER trg_sales_store_warehouse_alignment
BEFORE INSERT ON sales
BEGIN
    SELECT CASE
        WHEN (SELECT store_id FROM warehouses WHERE id = NEW.warehouse_id) != NEW.store_id
        THEN RAISE(ABORT, 'WAREHOUSE_DOES_NOT_BELONG_TO_SALE_STORE')
        WHEN (SELECT tenant_id FROM stores WHERE id = NEW.store_id) != NEW.tenant_id
        THEN RAISE(ABORT, 'STORE_DOES_NOT_BELONG_TO_SALE_TENANT')
    END;
END;

-- Device Sequence Ordering Guard (Anti-Replay Attack)
CREATE TRIGGER trg_sales_device_sequence_guard
BEFORE INSERT ON sales
WHEN NEW.device_seq_num IS NOT NULL
BEGIN
    SELECT CASE
        WHEN NEW.device_seq_num <= (SELECT last_seq_num FROM registered_devices WHERE id = NEW.device_id)
        THEN RAISE(ABORT, 'STALE_DEVICE_SEQUENCE_NUMBER_REPLAY_DETECTED')
    END;
END;

CREATE TRIGGER trg_sales_device_sequence_update
AFTER INSERT ON sales
WHEN NEW.device_seq_num IS NOT NULL
BEGIN
    UPDATE registered_devices
    SET last_seq_num = NEW.device_seq_num
    WHERE id = NEW.device_id;
END;

-- Offline Quotas: Safe Consumption Guard (Item, Warehouse, Tenant, Device, Expiry, and Line Quantity Alignment)
CREATE TRIGGER trg_sale_item_quota_deduction_guard
BEFORE INSERT ON sale_item_quota_deductions
BEGIN
    -- 1. Item matching
    SELECT CASE
        WHEN (SELECT stock_item_id FROM inventory_quotas WHERE id = NEW.quota_id) !=
             (SELECT stock_item_id FROM sale_items WHERE id = NEW.sale_item_id)
        THEN RAISE(ABORT, 'QUOTA_STOCK_ITEM_MISMATCH')
    END;

    -- 2. Device matching
    SELECT CASE
        WHEN (SELECT device_id FROM inventory_quotas WHERE id = NEW.quota_id) !=
             (SELECT s.device_id FROM sales s JOIN sale_items si ON si.sale_id = s.id WHERE si.id = NEW.sale_item_id)
        THEN RAISE(ABORT, 'QUOTA_DEVICE_MISMATCH')
    END;

    -- 3. Warehouse matching
    SELECT CASE
        WHEN (SELECT warehouse_id FROM inventory_quotas WHERE id = NEW.quota_id) !=
             (SELECT s.warehouse_id FROM sales s JOIN sale_items si ON si.sale_id = s.id WHERE si.id = NEW.sale_item_id)
        THEN RAISE(ABORT, 'QUOTA_WAREHOUSE_MISMATCH')
    END;

    -- 4. Tenant matching
    SELECT CASE
        WHEN (SELECT tenant_id FROM inventory_quotas WHERE id = NEW.quota_id) !=
             (SELECT s.tenant_id FROM sales s JOIN sale_items si ON si.sale_id = s.id WHERE si.id = NEW.sale_item_id)
        THEN RAISE(ABORT, 'QUOTA_TENANT_MISMATCH')
    END;

    -- 5. Deduction cannot exceed sale line quantity
    SELECT CASE
        WHEN NEW.deducted_quantity_ticks > (SELECT quantity_ticks FROM sale_items WHERE id = NEW.sale_item_id)
        THEN RAISE(ABORT, 'QUOTA_DEDUCTION_EXCEEDS_SALE_LINE_QUANTITY')
    END;

    -- 6. Quota status & expiry
    SELECT CASE
        WHEN (SELECT status FROM inventory_quotas WHERE id = NEW.quota_id) != 'ACTIVE'
        THEN RAISE(ABORT, 'QUOTA_IS_NOT_ACTIVE')
        WHEN (SELECT valid_until FROM inventory_quotas WHERE id = NEW.quota_id) < (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
        THEN RAISE(ABORT, 'QUOTA_HAS_EXPIRED')
    END;

    -- 7. Consumption cannot exceed remaining quota balance
    SELECT CASE
        WHEN (SELECT consumed_quantity_ticks + NEW.deducted_quantity_ticks FROM inventory_quotas WHERE id = NEW.quota_id) >
             (SELECT quota_quantity_ticks FROM inventory_quotas WHERE id = NEW.quota_id)
        THEN RAISE(ABORT, 'QUOTA_CONSUMPTION_EXCEEDS_REMAINING_BALANCE')
    END;
END;

CREATE TRIGGER trg_after_sale_item_quota_deduction_update
AFTER INSERT ON sale_item_quota_deductions
BEGIN
    UPDATE inventory_quotas
    SET consumed_quantity_ticks = consumed_quantity_ticks + NEW.deducted_quantity_ticks
    WHERE id = NEW.quota_id;
END;

-- Payment Allocations: Immutability, Party Matching & Strict Debt Limits
CREATE TRIGGER trg_payment_allocations_no_update
BEFORE UPDATE ON payment_allocations
BEGIN
    SELECT RAISE(ABORT, 'PAYMENT_ALLOCATIONS_ARE_IMMUTABLE_USE_REVERSAL_RECORD');
END;

CREATE TRIGGER trg_payment_allocations_no_delete
BEFORE DELETE ON payment_allocations
BEGIN
    SELECT RAISE(ABORT, 'PAYMENT_ALLOCATIONS_ARE_IMMUTABLE_USE_REVERSAL_RECORD');
END;

CREATE TRIGGER trg_check_allocation_walkin_sale
BEFORE INSERT ON payment_allocations
WHEN NEW.sale_id IS NOT NULL
BEGIN
    SELECT CASE
        WHEN (SELECT customer_id FROM sales WHERE id = NEW.sale_id) IS NULL
        THEN RAISE(ABORT, 'CANNOT_ALLOCATE_PAYMENT_TO_WALKIN_SALE_WITHOUT_CUSTOMER')
    END;
END;

CREATE TRIGGER trg_check_payment_total_allocation_insert
BEFORE INSERT ON payment_allocations
BEGIN
    SELECT CASE
        WHEN (SELECT is_reversal FROM payments WHERE id = NEW.payment_id) = 0
         AND (COALESCE((SELECT SUM(allocated_amount) FROM payment_allocations WHERE payment_id = NEW.payment_id), 0) + NEW.allocated_amount) >
             (SELECT amount FROM payments WHERE id = NEW.payment_id)
        THEN RAISE(ABORT, 'PAYMENT_ALLOCATION_EXCEEDS_PAYMENT_AMOUNT')
    END;
END;

CREATE TRIGGER trg_check_allocation_sale_debt_and_party
BEFORE INSERT ON payment_allocations
WHEN NEW.sale_id IS NOT NULL
BEGIN
    SELECT CASE
        WHEN (SELECT party_type FROM payments WHERE id = NEW.payment_id) != 'CUSTOMER'
        THEN RAISE(ABORT, 'PAYMENT_PARTY_TYPE_MUST_BE_CUSTOMER_FOR_SALE_ALLOCATION')
        WHEN (SELECT party_id FROM payments WHERE id = NEW.payment_id) !=
             (SELECT customer_id FROM sales WHERE id = NEW.sale_id)
        THEN RAISE(ABORT, 'PAYMENT_PARTY_MISMATCH_SALE_CUSTOMER')
        WHEN (SELECT is_reversal FROM payments WHERE id = NEW.payment_id) = 0
         AND NEW.allocated_amount > (SELECT remaining_debt FROM sales WHERE id = NEW.sale_id)
        THEN RAISE(ABORT, 'ALLOCATION_EXCEEDS_OUTSTANDING_INVOICE_DEBT')
    END;
END;

CREATE TRIGGER trg_check_allocation_purchase_debt_and_party
BEFORE INSERT ON payment_allocations
WHEN NEW.purchase_id IS NOT NULL
BEGIN
    SELECT CASE
        WHEN (SELECT party_type FROM payments WHERE id = NEW.payment_id) != 'SUPPLIER'
        THEN RAISE(ABORT, 'PAYMENT_PARTY_TYPE_MUST_BE_SUPPLIER_FOR_PURCHASE_ALLOCATION')
        WHEN (SELECT party_id FROM payments WHERE id = NEW.payment_id) !=
             (SELECT supplier_id FROM purchases WHERE id = NEW.purchase_id)
        THEN RAISE(ABORT, 'PAYMENT_PARTY_MISMATCH_PURCHASE_SUPPLIER')
        WHEN (SELECT is_reversal FROM payments WHERE id = NEW.payment_id) = 0
         AND NEW.allocated_amount > (SELECT remaining_debt FROM purchases WHERE id = NEW.purchase_id)
        THEN RAISE(ABORT, 'ALLOCATION_EXCEEDS_OUTSTANDING_PURCHASE_DEBT')
    END;
END;

CREATE TRIGGER trg_after_allocation_update_sale_balances
AFTER INSERT ON payment_allocations
WHEN NEW.sale_id IS NOT NULL
BEGIN
    UPDATE sales
    SET paid_amount = paid_amount + NEW.allocated_amount,
        remaining_debt = remaining_debt - NEW.allocated_amount
    WHERE id = NEW.sale_id;
END;

CREATE TRIGGER trg_after_allocation_update_purchase_balances
AFTER INSERT ON payment_allocations
WHEN NEW.purchase_id IS NOT NULL
BEGIN
    UPDATE purchases
    SET paid_amount = paid_amount + NEW.allocated_amount,
        remaining_debt = remaining_debt - NEW.allocated_amount
    WHERE id = NEW.purchase_id;
END;

CREATE TRIGGER trg_prevent_lowering_allocated_payment
BEFORE UPDATE OF amount ON payments
BEGIN
    SELECT CASE
        WHEN NEW.amount < COALESCE((SELECT SUM(allocated_amount) FROM payment_allocations WHERE payment_id = OLD.id), 0)
        THEN RAISE(ABORT, 'CANNOT_DOWNGRADE_PAYMENT_BELOW_ALLOCATED_TOTAL')
    END;
END;

-- Purchase Receipts: Order Alignment, StockItem Matching & Over-receipt Prevention
CREATE TRIGGER trg_purchase_receipt_item_guard
BEFORE INSERT ON purchase_receipt_items
BEGIN
    -- 1. Purchase order alignment
    SELECT CASE
        WHEN (SELECT purchase_id FROM purchase_items WHERE id = NEW.purchase_item_id) !=
             (SELECT purchase_id FROM purchase_receipts WHERE id = NEW.receipt_id)
        THEN RAISE(ABORT, 'RECEIPT_ITEM_PURCHASE_ORDER_MISMATCH')
    END;

    -- 2. StockItem alignment with purchase item
    SELECT CASE
        WHEN (SELECT stock_item_id FROM purchase_items WHERE id = NEW.purchase_item_id) != NEW.stock_item_id
        THEN RAISE(ABORT, 'RECEIPT_ITEM_STOCK_ITEM_MISMATCH')
    END;
    
    -- 3. Quantity check
    SELECT CASE
        WHEN (SELECT quantity_received_ticks + NEW.quantity_received_ticks FROM purchase_items WHERE id = NEW.purchase_item_id) >
             (SELECT quantity_ordered_ticks FROM purchase_items WHERE id = NEW.purchase_item_id)
        THEN RAISE(ABORT, 'RECEIPT_EXCEEDS_ORDERED_QUANTITY')
    END;
END;

CREATE TRIGGER trg_purchase_receipt_item_update_order_line
AFTER INSERT ON purchase_receipt_items
BEGIN
    UPDATE purchase_items
    SET quantity_received_ticks = quantity_received_ticks + NEW.quantity_received_ticks
    WHERE id = NEW.purchase_item_id;
END;

-- Purchase Returns: Order Alignment, StockItem Matching & Over-return Prevention
CREATE TRIGGER trg_purchase_return_item_guard
BEFORE INSERT ON purchase_return_items
BEGIN
    SELECT CASE
        WHEN (SELECT purchase_id FROM purchase_items WHERE id = NEW.purchase_item_id) !=
             (SELECT purchase_id FROM purchase_returns WHERE id = NEW.purchase_return_id)
        THEN RAISE(ABORT, 'RETURN_ITEM_PURCHASE_ORDER_MISMATCH')
        WHEN (SELECT stock_item_id FROM purchase_items WHERE id = NEW.purchase_item_id) != NEW.stock_item_id
        THEN RAISE(ABORT, 'RETURN_ITEM_STOCK_ITEM_MISMATCH')
        WHEN (SELECT quantity_returned_ticks + NEW.returned_quantity_ticks FROM purchase_items WHERE id = NEW.purchase_item_id) >
             (SELECT quantity_received_ticks FROM purchase_items WHERE id = NEW.purchase_item_id)
        THEN RAISE(ABORT, 'PURCHASE_RETURN_EXCEEDS_RECEIVED_QUANTITY')
    END;
END;

CREATE TRIGGER trg_purchase_return_item_update_order_line
AFTER INSERT ON purchase_return_items
BEGIN
    UPDATE purchase_items
    SET quantity_returned_ticks = quantity_returned_ticks + NEW.returned_quantity_ticks
    WHERE id = NEW.purchase_item_id;
END;

-- Sale Returns: Sale Alignment, StockItem Matching & Over-return Prevention
CREATE TRIGGER trg_sale_return_item_guard
BEFORE INSERT ON sale_return_items
BEGIN
    SELECT CASE
        WHEN (SELECT sale_id FROM sale_items WHERE id = NEW.original_sale_item_id) !=
             (SELECT original_sale_id FROM sale_returns WHERE id = NEW.return_id)
        THEN RAISE(ABORT, 'RETURN_ITEM_ORIGINAL_SALE_MISMATCH')
        WHEN (SELECT stock_item_id FROM sale_items WHERE id = NEW.original_sale_item_id) != NEW.stock_item_id
        THEN RAISE(ABORT, 'RETURN_ITEM_STOCK_ITEM_MISMATCH')
        WHEN (SELECT returned_quantity_ticks + NEW.returned_quantity_ticks FROM sale_items WHERE id = NEW.original_sale_item_id) >
             (SELECT quantity_ticks FROM sale_items WHERE id = NEW.original_sale_item_id)
        THEN RAISE(ABORT, 'SALE_RETURN_EXCEEDS_SOLD_QUANTITY')
    END;
END;

CREATE TRIGGER trg_sale_return_item_update_sale_line
AFTER INSERT ON sale_return_items
BEGIN
    UPDATE sale_items
    SET returned_quantity_ticks = returned_quantity_ticks + NEW.returned_quantity_ticks
    WHERE id = NEW.original_sale_item_id;
END;
