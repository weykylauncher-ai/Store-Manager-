package com.storemanager.core.data

import app.cash.sqldelight.db.SqlDriver

class StoreDatabaseManager(
    private val driverFactory: DatabaseDriverFactory
) {
    private var driver: SqlDriver? = null
    private var database: StoreDatabase? = null

    @Synchronized
    fun getDatabase(): StoreDatabase {
        if (database == null) {
            val d = driverFactory.createDriver()
            driver = d
            database = StoreDatabase(d)
        }
        return database!!
    }

    @Synchronized
    fun close() {
        driver?.close()
        driver = null
        database = null
    }
}
