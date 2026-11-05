package com.storemanager.core.data

import app.cash.sqldelight.db.QueryResult
import app.cash.sqldelight.db.SqlDriver
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.io.File

class StoreDatabaseIntegrationTest {

    private lateinit var tempDbFile: File
    private lateinit var factory: DatabaseDriverFactory
    private lateinit var driver: SqlDriver
    private lateinit var db: StoreDatabase

    @Before
    fun setUp() {
        tempDbFile = File.createTempFile("test_store_master_", ".db")
        if (tempDbFile.exists()) tempDbFile.delete()
        factory = DatabaseDriverFactory(tempDbFile)
        driver = factory.createDriver()
        db = StoreDatabase(driver)
    }

    @After
    fun tearDown() {
        driver.close()
        if (tempDbFile.exists()) tempDbFile.delete()
    }

    @Test
    fun test01_createDatabaseFromScratch_has55Tables() {
        val cursor = driver.executeQuery<Long>(
            null,
            "SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';",
            {
                it.next()
                QueryResult.Value(it.getLong(0) ?: 0L)
            },
            0
        )
        val tableCount = cursor.value
        assertEquals("Expected exactly 55 tables created by SQLDelight", 55L, tableCount)
    }

    @Test
    fun test02_hasAllCanonicalTriggers() {
        val cursor = driver.executeQuery<Long>(
            null,
            "SELECT count(*) FROM sqlite_master WHERE type='trigger';",
            {
                it.next()
                QueryResult.Value(it.getLong(0) ?: 0L)
            },
            0
        )
        val triggerCount = cursor.value
        assertEquals("Expected exactly 32 canonical triggers created", 32L, triggerCount)
    }

    @Test
    fun test03_pragmaForeignKeyCheck_returnsZeroErrors() {
        val cursor = driver.executeQuery<Long>(
            null,
            "PRAGMA foreign_key_check;",
            {
                var errorCount = 0L
                while (it.next().value) {
                    errorCount++
                }
                QueryResult.Value(errorCount)
            },
            0
        )
        assertEquals("PRAGMA foreign_key_check must return 0 errors", 0L, cursor.value)
    }

    @Test
    fun test04_pragmaIntegrityCheck_returnsOk() {
        val cursor = driver.executeQuery<String?>(
            null,
            "PRAGMA integrity_check;",
            {
                it.next()
                QueryResult.Value(it.getString(0))
            },
            0
        )
        assertEquals("PRAGMA integrity_check must return 'ok'", "ok", cursor.value)
    }

    @Test
    fun test05_checkConstraint_rejectsReservedExceedingOnHand() {
        try {
            driver.execute(
                null,
                """
                INSERT INTO inventory_balances (warehouse_id, stock_item_id, on_hand_ticks, reserved_ticks, current_moving_avg_cost)
                VALUES ('WH_TEST', 'SI_TEST', 100, 200, 50);
                """.trimIndent(),
                0
            )
            fail("Expected CHECK constraint violation when reserved_ticks > on_hand_ticks")
        } catch (e: Exception) {
            assertTrue("Expected integrity error", e.message?.contains("CHECK") == true || e.message?.contains("constraint") == true)
        }
    }

    @Test
    fun test06_seedBaselineAndQueriesExecution() {
        // Seed tenant
        db.storeDatabaseQueries.insertTenant("TENANT_TEST", "Test Enterprise", 1)
        val tenant = db.storeDatabaseQueries.selectTenantById("TENANT_TEST").executeAsOneOrNull()
        assertNotNull(tenant)
        assertEquals("Test Enterprise", tenant?.name)

        // Seed store
        db.storeDatabaseQueries.insertStore("STORE_TEST", "TENANT_TEST", "Branch 1", "B01")
        val stores = db.storeDatabaseQueries.selectAllStores().executeAsList()
        assertTrue(stores.any { it.id == "STORE_TEST" })
    }

    @Test
    fun test07_triggerFires_productNameOnlyAutoCreatesStockItemAndBalance() {
        // Seed prerequisites: base unit and default warehouse
        driver.execute(null, "INSERT INTO tenants (id, name) VALUES ('T_PROD', 'Prod Tenant');", 0)
        driver.execute(null, "INSERT INTO units_of_measure (id, tenant_id, name, symbol, dimension, is_base_unit) VALUES ('UOM_PIECE', 'T_PROD', 'Piece', 'pc', 'COUNT', 1);", 0)
        driver.execute(null, "INSERT INTO stores (id, tenant_id, name, code) VALUES ('STR_P', 'T_PROD', 'Store P', 'SP');", 0)
        driver.execute(null, "INSERT INTO warehouses (id, tenant_id, store_id, name, is_default) VALUES ('WH_DEF', 'T_PROD', 'STR_P', 'Default WH', 1);", 0)

        // Insert product by name only
        db.storeDatabaseQueries.insertProduct("P_AUTO_TEST", "T_PROD", "Fresh Milk 1L", "UOM_PIECE", 0, 1)

        // Verify stock_items was auto-created by trigger
        val stockItemCursor = driver.executeQuery<Pair<String, String>?>(
            null,
            "SELECT id, product_id FROM stock_items WHERE product_id = 'P_AUTO_TEST';",
            {
                if (it.next().value) {
                    QueryResult.Value(Pair(it.getString(0)!!, it.getString(1)!!))
                } else QueryResult.Value(null)
            },
            0
        )
        assertNotNull("Trigger must auto-create stock_items record", stockItemCursor.value)
        assertEquals("SI_P_AUTO_TEST", stockItemCursor.value?.first)

        // Verify inventory_balances was auto-created in default warehouse
        val balanceCursor = driver.executeQuery<Pair<Long, Long>?>(
            null,
            "SELECT on_hand_ticks, reserved_ticks FROM inventory_balances WHERE stock_item_id = 'SI_P_AUTO_TEST';",
            {
                if (it.next().value) {
                    QueryResult.Value(Pair(it.getLong(0)!!, it.getLong(1)!!))
                } else QueryResult.Value(null)
            },
            0
        )
        assertNotNull("Trigger must auto-create inventory_balances record", balanceCursor.value)
        assertEquals(0L, balanceCursor.value?.first)
        assertEquals(0L, balanceCursor.value?.second)
    }

    @Test
    fun test08_databaseReopen_preservesDataWithoutRecreatingSchema() {
        // Insert a record
        db.storeDatabaseQueries.insertTenant("TENANT_PERSIST", "Persistent Enterprise", 1)

        // Close driver
        driver.close()

        // Reopen database with new factory on same file
        val reopenFactory = DatabaseDriverFactory(tempDbFile)
        val newDriver = reopenFactory.createDriver()
        val newDb = StoreDatabase(newDriver)

        try {
            val tenant = newDb.storeDatabaseQueries.selectTenantById("TENANT_PERSIST").executeAsOneOrNull()
            assertNotNull("Data must persist across database reopens", tenant)
            assertEquals("Persistent Enterprise", tenant?.name)
        } finally {
            newDriver.close()
        }
    }

    @Test
    fun test09_auditLogsImmutability_rejectsUpdateAndDelete() {
        driver.execute(null, "INSERT INTO tenants (id, name) VALUES ('T_AUDIT', 'Audit Tenant');", 0)
        driver.execute(null, "INSERT INTO audit_logs (id, tenant_id, action, entity_name, entity_id) VALUES ('A_01', 'T_AUDIT', 'INSERT', 'sales', 'S_01');", 0)

        // Test UPDATE rejection
        try {
            driver.execute(null, "UPDATE audit_logs SET action = 'MODIFIED' WHERE id = 'A_01';", 0)
            fail("Trigger must reject UPDATE on audit_logs")
        } catch (e: Exception) {
            assertTrue("Expected audit log update rejection", e.message?.contains("AUDIT_LOGS_ARE_APPEND_ONLY") == true)
        }

        // Test DELETE rejection
        try {
            driver.execute(null, "DELETE FROM audit_logs WHERE id = 'A_01';", 0)
            fail("Trigger must reject DELETE on audit_logs")
        } catch (e: Exception) {
            assertTrue("Expected audit log delete rejection", e.message?.contains("AUDIT_LOGS_ARE_APPEND_ONLY") == true)
        }
    }

    @Test
    fun test10_transactionRollback_cleansUpAtomicallyOnFailure() {
        driver.execute(null, "INSERT INTO tenants (id, name) VALUES ('T_TX', 'Tx Tenant');", 0)

        try {
            driver.execute(null, "BEGIN TRANSACTION;", 0)
            driver.execute(null, "INSERT INTO tenants (id, name) VALUES ('T_FAIL_1', 'Will Rollback');", 0)
            // Intentionally fail by duplicating primary key
            driver.execute(null, "INSERT INTO tenants (id, name) VALUES ('T_FAIL_1', 'Duplicate PK');", 0)
            driver.execute(null, "COMMIT;", 0)
            fail("Expected transaction failure")
        } catch (e: Exception) {
            driver.execute(null, "ROLLBACK;", 0)
        }

        val tenant = db.storeDatabaseQueries.selectTenantById("T_FAIL_1").executeAsOneOrNull()
        assertEquals("Rolled back record must not exist", null, tenant)
    }
}
