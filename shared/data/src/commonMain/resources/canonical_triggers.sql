-- Store Manager Pro - Triggers Definition (32 Canonical Triggers)
-- Executed atomically during database initialization via DatabaseDriverFactory.

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

CREATE TRIGGER trg_stock_item_variant_consistency_insert
BEFORE INSERT ON stock_items
WHEN NEW.variant_id IS NOT NULL
BEGIN
    SELECT CASE
        WHEN (SELECT product_id FROM product_variants WHERE id = NEW.variant_id) != NEW.product_id
        THEN RAISE(ABORT, 'VARIANT_DOES_NOT_BELONG_TO_SPECIFIED_PRODUCT')
    END;

CREATE TRIGGER trg_stock_item_variant_consistency_update
BEFORE UPDATE OF product_id, variant_id ON stock_items
WHEN NEW.variant_id IS NOT NULL
BEGIN
    SELECT CASE
        WHEN (SELECT product_id FROM product_variants WHERE id = NEW.variant_id) != NEW.product_id
        THEN RAISE(ABORT, 'VARIANT_DOES_NOT_BELONG_TO_SPECIFIED_PRODUCT')
    END;

CREATE TRIGGER trg_sales_store_warehouse_alignment
BEFORE INSERT ON sales
BEGIN
    SELECT CASE
        WHEN (SELECT store_id FROM warehouses WHERE id = NEW.warehouse_id) != NEW.store_id
        THEN RAISE(ABORT, 'WAREHOUSE_DOES_NOT_BELONG_TO_SALE_STORE')
        WHEN (SELECT tenant_id FROM stores WHERE id = NEW.store_id) != NEW.tenant_id
        THEN RAISE(ABORT, 'STORE_DOES_NOT_BELONG_TO_SALE_TENANT')
    END;

CREATE TRIGGER trg_sales_device_sequence_guard
BEFORE INSERT ON sales
WHEN NEW.device_seq_num IS NOT NULL
BEGIN
    SELECT CASE
        WHEN NEW.device_seq_num <= (SELECT last_seq_num FROM registered_devices WHERE id = NEW.device_id)
        THEN RAISE(ABORT, 'STALE_DEVICE_SEQUENCE_NUMBER_REPLAY_DETECTED')
    END;

CREATE TRIGGER trg_sales_device_sequence_update
AFTER INSERT ON sales
WHEN NEW.device_seq_num IS NOT NULL
BEGIN
    UPDATE registered_devices
    SET last_seq_num = NEW.device_seq_num
    WHERE id = NEW.device_id;
END;

CREATE TRIGGER trg_sale_item_quota_deduction_guard
BEFORE INSERT ON sale_item_quota_deductions
BEGIN
    -- 1. Item matching
    SELECT CASE
        WHEN (SELECT stock_item_id FROM inventory_quotas WHERE id = NEW.quota_id) !=
             (SELECT stock_item_id FROM sale_items WHERE id = NEW.sale_item_id)
        THEN RAISE(ABORT, 'QUOTA_STOCK_ITEM_MISMATCH')
    END;

CREATE TRIGGER trg_after_sale_item_quota_deduction_update
AFTER INSERT ON sale_item_quota_deductions
BEGIN
    UPDATE inventory_quotas
    SET consumed_quantity_ticks = consumed_quantity_ticks + NEW.deducted_quantity_ticks
    WHERE id = NEW.quota_id;
END;

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

CREATE TRIGGER trg_check_payment_total_allocation_insert
BEFORE INSERT ON payment_allocations
BEGIN
    SELECT CASE
        WHEN (SELECT is_reversal FROM payments WHERE id = NEW.payment_id) = 0
         AND (COALESCE((SELECT SUM(allocated_amount) FROM payment_allocations WHERE payment_id = NEW.payment_id), 0) + NEW.allocated_amount) >
             (SELECT amount FROM payments WHERE id = NEW.payment_id)
        THEN RAISE(ABORT, 'PAYMENT_ALLOCATION_EXCEEDS_PAYMENT_AMOUNT')
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

CREATE TRIGGER trg_purchase_receipt_item_guard
BEFORE INSERT ON purchase_receipt_items
BEGIN
    -- 1. Purchase order alignment
    SELECT CASE
        WHEN (SELECT purchase_id FROM purchase_items WHERE id = NEW.purchase_item_id) !=
             (SELECT purchase_id FROM purchase_receipts WHERE id = NEW.receipt_id)
        THEN RAISE(ABORT, 'RECEIPT_ITEM_PURCHASE_ORDER_MISMATCH')
    END;

CREATE TRIGGER trg_purchase_receipt_item_update_order_line
AFTER INSERT ON purchase_receipt_items
BEGIN
    UPDATE purchase_items
    SET quantity_received_ticks = quantity_received_ticks + NEW.quantity_received_ticks
    WHERE id = NEW.purchase_item_id;
END;

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

CREATE TRIGGER trg_purchase_return_item_update_order_line
AFTER INSERT ON purchase_return_items
BEGIN
    UPDATE purchase_items
    SET quantity_returned_ticks = quantity_returned_ticks + NEW.returned_quantity_ticks
    WHERE id = NEW.purchase_item_id;
END;

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

CREATE TRIGGER trg_sale_return_item_update_sale_line
AFTER INSERT ON sale_return_items
BEGIN
    UPDATE sale_items
    SET returned_quantity_ticks = returned_quantity_ticks + NEW.returned_quantity_ticks
    WHERE id = NEW.original_sale_item_id;
END;

