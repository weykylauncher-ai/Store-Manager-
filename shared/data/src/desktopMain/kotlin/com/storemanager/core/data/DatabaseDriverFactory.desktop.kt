package com.storemanager.core.data

import app.cash.sqldelight.db.QueryResult
import app.cash.sqldelight.db.SqlDriver
import app.cash.sqldelight.driver.jdbc.sqlite.JdbcSqliteDriver
import java.io.File
import java.io.RandomAccessFile
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.Properties
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

data class ColumnSchemaInfo(
    val name: String,
    val type: String,
    val notnull: Long,
    val defaultValue: String?,
    val pk: Long
)

data class SchemaObjectDefinition(
    val type: String,
    val name: String,
    val tblName: String,
    val sql: String
)

class CanonicalSchemaBaseline(
    val tableNames: List<String>,
    val tableColumns: Map<String, List<ColumnSchemaInfo>>,
    val indexes: Map<String, SchemaObjectDefinition>,
    val triggers: Map<String, SchemaObjectDefinition>,
    val fingerprint: String
)

actual class DatabaseDriverFactory(
    private val dbFile: File? = null
) {
    internal var simulateTriggerFailure: Boolean = false
    internal var checkpointResultOverride: Triple<Long, Long, Long>? = null
    internal var simulateStagingWalSidecarFailure: Boolean = false
    internal var simulateSidecarCleanupFailure: Boolean = false
    internal var simulateTargetCollisionDuringMove: Boolean = false
    internal var simulateTargetCollision0Byte: Boolean = false
    internal var customTriggerScript: String? = null
    internal var initDelayMs: Long = 0L
    internal var driverWrapper: ((SqlDriver) -> SqlDriver)? = null

    actual fun createDriver(): SqlDriver {
        val targetFile = dbFile ?: getDefaultDatabaseFile()
        val parentDir = targetFile.parentFile ?: File(".")
        if (!parentDir.exists()) {
            parentDir.mkdirs()
        }

        val canonicalPath = targetFile.canonicalPath
        val jvmLock = inJvmLocks.computeIfAbsent(canonicalPath) { Any() }
        val isNewDatabase: Boolean

        // Thread-safe within JVM + Process-safe across OS processes via FileChannel.lock
        synchronized(jvmLock) {
            val lockFile = File(parentDir, "${targetFile.name}.init.lock")
            RandomAccessFile(lockFile, "rw").use { raf ->
                raf.channel.lock().use {
                    // Check target existence strictly after acquiring exclusive lock
                    if (!targetFile.exists()) {
                        isNewDatabase = true
                        initializeNewDatabaseAtomically(targetFile, parentDir)
                    } else {
                        isNewDatabase = false
                    }
                }
            }
        }

        // Open connection to verified target database
        val properties = createConnectionProperties()
        val url = "jdbc:sqlite:${targetFile.absolutePath}"
        val driver = JdbcSqliteDriver(url, properties)

        // Apply per-connection runtime PRAGMAs
        applyConnectionRuntimePragmas(driver)

        if (!isNewDatabase) {
            // Validate existing database before modifying any persistent database properties
            try {
                validateExistingDatabase(driver)
                // Only after validation succeeds, ensure persistent journal_mode is WAL
                driver.execute(null, "PRAGMA journal_mode = WAL;", 0)
            } catch (e: Throwable) {
                try { driver.close() } catch (_: Throwable) {}
                // Never delete, wipe, or alter existing file on validation rejection
                throw e
            }
        }

        return driverWrapper?.invoke(driver) ?: driver
    }

    private fun createConnectionProperties(): Properties {
        return Properties().apply {
            put("foreign_keys", "true")
            put("busy_timeout", "10000") // 10 seconds busy timeout
            put("synchronous", "FULL")   // Full synchronous durability for financial and inventory safety
        }
    }

    private fun applyConnectionRuntimePragmas(driver: SqlDriver) {
        driver.execute(null, "PRAGMA foreign_keys = ON;", 0)
        driver.execute(null, "PRAGMA busy_timeout = 10000;", 0)
        driver.execute(null, "PRAGMA synchronous = FULL;", 0)
    }

    private fun initializeNewDatabaseAtomically(targetFile: File, parentDir: File) {
        if (initDelayMs > 0L) {
            Thread.sleep(initDelayMs)
        }

        // Staging file is created strictly in the SAME directory as the target database
        val stagingFile = File(
            parentDir,
            "${targetFile.name}.staging.${System.currentTimeMillis()}_${UUID.randomUUID().toString().take(8)}"
        )

        var stagingDriver: SqlDriver? = null
        try {
            val properties = Properties().apply {
                put("foreign_keys", "true")
                put("busy_timeout", "10000")
                put("journal_mode", "WAL")
                put("synchronous", "FULL")
            }
            val stagingUrl = "jdbc:sqlite:${stagingFile.absolutePath}"
            stagingDriver = JdbcSqliteDriver(stagingUrl, properties)

            // Configure staging connection
            stagingDriver.execute(null, "PRAGMA foreign_keys = ON;", 0)
            stagingDriver.execute(null, "PRAGMA busy_timeout = 10000;", 0)
            stagingDriver.execute(null, "PRAGMA journal_mode = WAL;", 0)
            stagingDriver.execute(null, "PRAGMA synchronous = FULL;", 0)

            // 1. Create 55 Tables and 107 explicit unique/functional indexes from SQLDelight schema
            StoreDatabase.Schema.create(stagingDriver)

            // 2. Execute 186 canonical triggers
            if (simulateTriggerFailure) {
                val script = customTriggerScript ?: loadCanonicalTriggerScript()
                val parts = script.split("CREATE TRIGGER").filter { it.trim().isNotBlank() }
                for (i in 0 until (parts.size / 2).coerceAtLeast(1)) {
                    val statement = "CREATE TRIGGER " + parts[i].trim()
                    stagingDriver.execute(null, statement, 0)
                }
                throw IllegalStateException("Simulated mid-trigger failure during database initialization")
            } else {
                val script = customTriggerScript ?: loadCanonicalTriggerScript()
                executeTriggerScript(stagingDriver, script)
            }

            // 3. Validate newly initialized staging schema before setting user_version
            validateCountsAndIntegrity(stagingDriver)
            validateExactSchema(stagingDriver)

            // 4. Mark database baseline version
            stagingDriver.execute(null, "PRAGMA user_version = $EXPECTED_USER_VERSION;", 0)

            // 5. WAL Checkpoint Verification: read checkpoint results and verify no busy frames remain
            val checkpointResult = queryCheckpoint(stagingDriver)
            val busy = checkpointResult.first
            val log = checkpointResult.second
            val checkpointed = checkpointResult.third

            if (busy != 0L) {
                throw DatabaseInitializationException("WAL checkpoint blocked: busy flag = $busy")
            }
            if (checkpointed < log) {
                throw DatabaseInitializationException("WAL checkpoint incomplete: checkpointed $checkpointed of $log frames")
            }

            // Close staging driver cleanly before publication
            stagingDriver.close()
            stagingDriver = null

            // 6. Verify sidecar files: no non-empty WAL/SHM files may remain
            val stagingWal = File("${stagingFile.absolutePath}-wal")
            val stagingShm = File("${stagingFile.absolutePath}-shm")
            if (simulateStagingWalSidecarFailure) {
                stagingWal.writeBytes(byteArrayOf(1, 2, 3, 4, 5))
            }
            if (stagingWal.exists()) {
                if (stagingWal.length() > 0L) {
                    throw DatabaseInitializationException("Staging WAL sidecar contains uncheckpointed data (${stagingWal.length()} bytes)")
                }
                val deleted = stagingWal.delete()
                if (!deleted && stagingWal.exists()) {
                    throw DatabaseInitializationException("Failed to remove staging WAL sidecar before publication")
                }
            }
            if (stagingShm.exists()) {
                val deleted = stagingShm.delete()
                if (!deleted && stagingShm.exists()) {
                    throw DatabaseInitializationException("Failed to remove staging SHM sidecar before publication")
                }
            }
            if (simulateSidecarCleanupFailure) {
                throw DatabaseInitializationException("Simulated failure to remove staging sidecar file")
            }

            // 7. Secure Atomic Publication:
            // Check collision: Never replace an existing database file under any circumstance
            if (simulateTargetCollisionDuringMove) {
                if (simulateTargetCollision0Byte) {
                    targetFile.writeText("")
                } else {
                    targetFile.writeText("PRE_EXISTING_TARGET_FILE_MARKER")
                }
            }
            if (targetFile.exists()) {
                throw DatabaseInitializationException(
                    "Publication aborted: target database file already exists at ${targetFile.absolutePath}. Replacing existing databases is strictly prohibited."
                )
            }

            // Move using ATOMIC_MOVE strictly — NO fallback to REPLACE_EXISTING
            try {
                Files.move(
                    stagingFile.toPath(),
                    targetFile.toPath(),
                    StandardCopyOption.ATOMIC_MOVE
                )
            } catch (e: AtomicMoveNotSupportedException) {
                throw DatabaseInitializationException(
                    "Filesystem does not support ATOMIC_MOVE across target path. Staging aborted to protect integrity.",
                    e
                )
            } catch (e: Exception) {
                throw DatabaseInitializationException(
                    "Atomic publication failed: ${e.message}",
                    e
                )
            }
        } catch (e: Throwable) {
            // Safely close staging driver
            try { stagingDriver?.close() } catch (_: Throwable) {}
            // Clean up staging files completely
            cleanFileAndSidecars(stagingFile)
            // CRITICAL: The initialization cleanup routine must never delete, replace, or modify an existing target file
            throw DatabaseInitializationException(
                "Database initialization failed and staging was cleaned up: ${e.message}",
                e
            )
        }
    }

    private fun queryCheckpoint(driver: SqlDriver): Triple<Long, Long, Long> {
        checkpointResultOverride?.let { return it }
        val cursor = driver.executeQuery<Triple<Long, Long, Long>>(
            null,
            "PRAGMA wal_checkpoint(TRUNCATE);",
            {
                it.next()
                val busy = it.getLong(0) ?: 0L
                val log = it.getLong(1) ?: 0L
                val checkpointed = it.getLong(2) ?: 0L
                QueryResult.Value(Triple(busy, log, checkpointed))
            },
            0
        )
        return cursor.value
    }

    private fun loadCanonicalTriggerScript(): String {
        val stream = this::class.java.classLoader.getResourceAsStream("canonical_triggers.sql")
            ?: error("canonical_triggers.sql resource not found in classpath")
        return stream.bufferedReader().use { it.readText() }
    }

    private fun executeTriggerScript(driver: SqlDriver, script: String) {
        val parts = script.split("CREATE TRIGGER")
        for (part in parts) {
            val trimmed = part.trim()
            if (trimmed.isNotBlank()) {
                val statement = "CREATE TRIGGER " + trimmed
                driver.execute(null, statement, 0)
            }
        }
    }

    private fun cleanFileAndSidecars(baseFile: File) {
        if (baseFile.exists()) baseFile.delete()
        File("${baseFile.absolutePath}-wal").takeIf { it.exists() }?.delete()
        File("${baseFile.absolutePath}-shm").takeIf { it.exists() }?.delete()
    }

    fun validateExistingDatabase(driver: SqlDriver) {
        // 1. Verify PRAGMA user_version
        val userVersion = querySingleLong(driver, "PRAGMA user_version;")
        if (userVersion != EXPECTED_USER_VERSION) {
            throw DatabaseValidationException(
                "Invalid database user_version: found $userVersion, expected $EXPECTED_USER_VERSION. Database rejected."
            )
        }

        // 2. Validate tables, indexes, triggers counts and SQLite integrity
        validateCountsAndIntegrity(driver)

        // 3. Exact validation of names, definitions, column structures, and canonical fingerprint
        validateExactSchema(driver)
    }

    private fun validateCountsAndIntegrity(driver: SqlDriver) {
        // Tables count
        val tableCount = querySingleLong(
            driver,
            "SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';"
        )
        if (tableCount != EXPECTED_TABLE_COUNT) {
            throw DatabaseValidationException(
                "Incomplete database schema: found $tableCount tables, expected $EXPECTED_TABLE_COUNT."
            )
        }

        // Indexes count
        val indexCount = querySingleLong(
            driver,
            "SELECT count(*) FROM sqlite_master WHERE type='index' AND sql IS NOT NULL;"
        )
        if (indexCount != EXPECTED_INDEX_COUNT) {
            throw DatabaseValidationException(
                "Incomplete database schema: found $indexCount explicit indexes, expected $EXPECTED_INDEX_COUNT."
            )
        }

        // Triggers count
        val triggerCount = querySingleLong(
            driver,
            "SELECT count(*) FROM sqlite_master WHERE type='trigger';"
        )
        if (triggerCount != EXPECTED_TRIGGER_COUNT) {
            throw DatabaseValidationException(
                "Incomplete database schema: found $triggerCount triggers, expected $EXPECTED_TRIGGER_COUNT."
            )
        }

        // Integrity check
        val integrityResult = querySingleString(driver, "PRAGMA integrity_check;")
        if (integrityResult != "ok") {
            throw DatabaseValidationException(
                "Database integrity check failed: $integrityResult"
            )
        }

        // Foreign key check
        val fkErrors = countRows(driver, "PRAGMA foreign_key_check;")
        if (fkErrors > 0) {
            throw DatabaseValidationException(
                "Database foreign key check failed with $fkErrors violations."
            )
        }
    }

    fun validateExactSchema(driver: SqlDriver) {
        val baseline = canonicalBaseline

        // 1. Verify exact Table Names
        val targetTables = queryTableNames(driver)
        if (targetTables.size.toLong() != EXPECTED_TABLE_COUNT) {
            throw DatabaseValidationException(
                "Schema validation failed: expected $EXPECTED_TABLE_COUNT tables, found ${targetTables.size}"
            )
        }
        val missingTables = baseline.tableNames - targetTables.toSet()
        val extraTables = targetTables.toSet() - baseline.tableNames.toSet()
        if (missingTables.isNotEmpty() || extraTables.isNotEmpty()) {
            throw DatabaseValidationException(
                "Schema validation failed: table mismatch. Missing: $missingTables, Unexpected: $extraTables"
            )
        }

        // 2. Verify Column Definitions & Constraints for each table
        for (tableName in baseline.tableNames) {
            val expectedCols = baseline.tableColumns[tableName] ?: emptyList()
            val actualCols = queryTableColumns(driver, tableName)
            if (actualCols.size != expectedCols.size) {
                throw DatabaseValidationException(
                    "Schema validation failed for table '$tableName': column count mismatch (expected ${expectedCols.size}, found ${actualCols.size})"
                )
            }
            for (i in expectedCols.indices) {
                val exp = expectedCols[i]
                val act = actualCols.getOrNull(i)
                if (act == null || act.name != exp.name || act.type != exp.type ||
                    act.notnull != exp.notnull || act.defaultValue != exp.defaultValue || act.pk != exp.pk
                ) {
                    throw DatabaseValidationException(
                        "Schema validation failed for table '$tableName': column '${exp.name}' mismatch (expected $exp, found $act)"
                    )
                }
            }
        }

        // 3. Verify exact Explicit Index names and definitions
        val targetIndexes = queryIndexes(driver)
        if (targetIndexes.size.toLong() != EXPECTED_INDEX_COUNT) {
            throw DatabaseValidationException(
                "Schema validation failed: expected $EXPECTED_INDEX_COUNT explicit indexes, found ${targetIndexes.size}"
            )
        }
        val missingIndexes = baseline.indexes.keys - targetIndexes.keys
        val extraIndexes = targetIndexes.keys - baseline.indexes.keys
        if (missingIndexes.isNotEmpty() || extraIndexes.isNotEmpty()) {
            throw DatabaseValidationException(
                "Schema validation failed: explicit index mismatch. Missing: $missingIndexes, Unexpected: $extraIndexes"
            )
        }
        for ((name, expIdx) in baseline.indexes) {
            val actIdx = targetIndexes[name]
                ?: throw DatabaseValidationException("Schema validation failed: missing index '$name'")
            if (actIdx.tblName != expIdx.tblName || normalizeSql(actIdx.sql) != normalizeSql(expIdx.sql)) {
                throw DatabaseValidationException(
                    "Schema validation failed: index '$name' definition altered."
                )
            }
        }

        // 4. Verify exact Trigger names and definitions
        val targetTriggers = queryTriggers(driver)
        if (targetTriggers.size.toLong() != EXPECTED_TRIGGER_COUNT) {
            throw DatabaseValidationException(
                "Schema validation failed: expected $EXPECTED_TRIGGER_COUNT triggers, found ${targetTriggers.size}"
            )
        }
        val missingTriggers = baseline.triggers.keys - targetTriggers.keys
        val extraTriggers = targetTriggers.keys - baseline.triggers.keys
        if (missingTriggers.isNotEmpty() || extraTriggers.isNotEmpty()) {
            throw DatabaseValidationException(
                "Schema validation failed: trigger mismatch. Missing: $missingTriggers, Unexpected: $extraTriggers"
            )
        }
        for ((name, expTrg) in baseline.triggers) {
            val actTrg = targetTriggers[name]
                ?: throw DatabaseValidationException("Schema validation failed: missing trigger '$name'")
            if (actTrg.tblName != expTrg.tblName || normalizeSql(actTrg.sql) != normalizeSql(expTrg.sql)) {
                throw DatabaseValidationException(
                    "Schema validation failed: trigger '$name' definition altered."
                )
            }
        }

        // 5. Verify Canonical Schema Fingerprint
        val targetFingerprint = computeSchemaFingerprint(targetTables, driver, targetIndexes, targetTriggers)
        if (targetFingerprint != baseline.fingerprint) {
            throw DatabaseValidationException(
                "Schema validation failed: canonical schema fingerprint mismatch (expected ${baseline.fingerprint}, found $targetFingerprint)"
            )
        }
    }

    private fun querySingleLong(driver: SqlDriver, sql: String): Long {
        val cursor = driver.executeQuery<Long>(
            null,
            sql,
            {
                it.next()
                QueryResult.Value(it.getLong(0) ?: 0L)
            },
            0
        )
        return cursor.value
    }

    private fun querySingleString(driver: SqlDriver, sql: String): String? {
        val cursor = driver.executeQuery<String?>(
            null,
            sql,
            {
                it.next()
                QueryResult.Value(it.getString(0))
            },
            0
        )
        return cursor.value
    }

    private fun countRows(driver: SqlDriver, sql: String): Long {
        val cursor = driver.executeQuery<Long>(
            null,
            sql,
            {
                var count = 0L
                while (it.next().value) {
                    count++
                }
                QueryResult.Value(count)
            },
            0
        )
        return cursor.value
    }

    companion object {
        private val inJvmLocks = ConcurrentHashMap<String, Any>()

        const val EXPECTED_TABLE_COUNT = 55L
        const val EXPECTED_INDEX_COUNT = 107L
        const val EXPECTED_TRIGGER_COUNT = 186L
        const val EXPECTED_USER_VERSION = 1L

        val canonicalBaseline: CanonicalSchemaBaseline by lazy {
            buildCanonicalBaseline()
        }

        fun normalizeSql(sql: String?): String {
            if (sql == null) return ""
            return sql.replace(Regex("\\s+"), " ").trim()
        }

        fun computeSha256(data: String): String {
            val md = MessageDigest.getInstance("SHA-256")
            val bytes = md.digest(data.toByteArray(Charsets.UTF_8))
            return bytes.joinToString("") { "%02x".format(it) }
        }

        fun queryTableNames(driver: SqlDriver): List<String> {
            val cursor = driver.executeQuery<List<String>>(
                null,
                "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;",
                {
                    val list = mutableListOf<String>()
                    while (it.next().value) {
                        list.add(it.getString(0)!!)
                    }
                    QueryResult.Value(list)
                },
                0
            )
            return cursor.value
        }

        fun queryTableColumns(driver: SqlDriver, tableName: String): List<ColumnSchemaInfo> {
            val cursor = driver.executeQuery<List<ColumnSchemaInfo>>(
                null,
                "PRAGMA table_info($tableName);",
                {
                    val colList = mutableListOf<ColumnSchemaInfo>()
                    while (it.next().value) {
                        val name = it.getString(1) ?: ""
                        val type = (it.getString(2) ?: "").uppercase()
                        val notnull = it.getLong(3) ?: 0L
                        val dflt = it.getString(4)
                        val pk = it.getLong(5) ?: 0L
                        colList.add(ColumnSchemaInfo(name, type, notnull, dflt, pk))
                    }
                    QueryResult.Value(colList)
                },
                0
            )
            return cursor.value
        }

        fun queryIndexes(driver: SqlDriver): Map<String, SchemaObjectDefinition> {
            val cursor = driver.executeQuery<Map<String, SchemaObjectDefinition>>(
                null,
                "SELECT type, name, tbl_name, sql FROM sqlite_master WHERE type='index' AND sql IS NOT NULL ORDER BY name;",
                {
                    val map = mutableMapOf<String, SchemaObjectDefinition>()
                    while (it.next().value) {
                        val type = it.getString(0) ?: "index"
                        val name = it.getString(1) ?: ""
                        val tblName = it.getString(2) ?: ""
                        val sql = it.getString(3) ?: ""
                        map[name] = SchemaObjectDefinition(type, name, tblName, sql)
                    }
                    QueryResult.Value(map)
                },
                0
            )
            return cursor.value
        }

        fun queryTriggers(driver: SqlDriver): Map<String, SchemaObjectDefinition> {
            val cursor = driver.executeQuery<Map<String, SchemaObjectDefinition>>(
                null,
                "SELECT type, name, tbl_name, sql FROM sqlite_master WHERE type='trigger' ORDER BY name;",
                {
                    val map = mutableMapOf<String, SchemaObjectDefinition>()
                    while (it.next().value) {
                        val type = it.getString(0) ?: "trigger"
                        val name = it.getString(1) ?: ""
                        val tblName = it.getString(2) ?: ""
                        val sql = it.getString(3) ?: ""
                        map[name] = SchemaObjectDefinition(type, name, tblName, sql)
                    }
                    QueryResult.Value(map)
                },
                0
            )
            return cursor.value
        }

        private fun computeSchemaFingerprint(
            tableNames: List<String>,
            driver: SqlDriver,
            indexes: Map<String, SchemaObjectDefinition>,
            triggers: Map<String, SchemaObjectDefinition>
        ): String {
            val rep = buildString {
                append("TABLES:")
                for (t in tableNames.sorted()) {
                    append("[$t:")
                    val cols = queryTableColumns(driver, t)
                    for (c in cols) {
                        append("(${c.name},${c.type},${c.notnull},${c.defaultValue},${c.pk})")
                    }
                    append("]")
                }
                append(";INDEXES:")
                for ((name, idx) in indexes.toSortedMap()) {
                    append("[$name:${idx.tblName}:${normalizeSql(idx.sql)}]")
                }
                append(";TRIGGERS:")
                for ((name, trg) in triggers.toSortedMap()) {
                    append("[$name:${trg.tblName}:${normalizeSql(trg.sql)}]")
                }
            }
            return computeSha256(rep)
        }

        private fun buildCanonicalBaseline(): CanonicalSchemaBaseline {
            val memDriver = JdbcSqliteDriver(JdbcSqliteDriver.IN_MEMORY)
            try {
                memDriver.execute(null, "PRAGMA foreign_keys = ON;", 0)
                StoreDatabase.Schema.create(memDriver)
                val factory = DatabaseDriverFactory()
                val triggerScript = factory.loadCanonicalTriggerScript()
                factory.executeTriggerScript(memDriver, triggerScript)

                val tables = queryTableNames(memDriver)
                val tableColumns = mutableMapOf<String, List<ColumnSchemaInfo>>()
                for (t in tables) {
                    tableColumns[t] = queryTableColumns(memDriver, t)
                }
                val indexes = queryIndexes(memDriver)
                val triggers = queryTriggers(memDriver)

                val rep = buildString {
                    append("TABLES:")
                    for (t in tables.sorted()) {
                        append("[$t:")
                        val cols = tableColumns[t] ?: emptyList()
                        for (c in cols) {
                            append("(${c.name},${c.type},${c.notnull},${c.defaultValue},${c.pk})")
                        }
                        append("]")
                    }
                    append(";INDEXES:")
                    for ((name, idx) in indexes.toSortedMap()) {
                        append("[$name:${idx.tblName}:${normalizeSql(idx.sql)}]")
                    }
                    append(";TRIGGERS:")
                    for ((name, trg) in triggers.toSortedMap()) {
                        append("[$name:${trg.tblName}:${normalizeSql(trg.sql)}]")
                    }
                }
                val fingerprint = computeSha256(rep)

                return CanonicalSchemaBaseline(
                    tableNames = tables,
                    tableColumns = tableColumns,
                    indexes = indexes,
                    triggers = triggers,
                    fingerprint = fingerprint
                )
            } finally {
                try { memDriver.close() } catch (_: Throwable) {}
            }
        }

        fun getDefaultDatabaseFile(): File {
            val os = System.getProperty("os.name").lowercase()
            val baseDir = when {
                os.contains("win") -> {
                    val appData = System.getenv("LOCALAPPDATA")
                        ?: (System.getProperty("user.home") + "\\AppData\\Local")
                    File(appData, "StoreManagerPro\\data")
                }
                os.contains("mac") -> {
                    File(System.getProperty("user.home"), "Library/Application Support/StoreManagerPro/data")
                }
                else -> { // Linux / Unix
                    val xdgData = System.getenv("XDG_DATA_HOME")
                    if (!xdgData.isNullOrBlank()) {
                        File(xdgData, "storemanagerpro/data")
                    } else {
                        File(System.getProperty("user.home"), ".local/share/storemanagerpro/data")
                    }
                }
            }
            return File(baseDir, "store_manager_master.db")
        }

        fun createInMemoryDriver(): SqlDriver {
            val properties = Properties().apply {
                put("foreign_keys", "true")
                put("busy_timeout", "10000")
                put("synchronous", "FULL")
            }
            val driver = JdbcSqliteDriver(JdbcSqliteDriver.IN_MEMORY, properties)
            driver.execute(null, "PRAGMA foreign_keys = ON;", 0)
            driver.execute(null, "PRAGMA busy_timeout = 10000;", 0)
            driver.execute(null, "PRAGMA synchronous = FULL;", 0)

            StoreDatabase.Schema.create(driver)

            val factory = DatabaseDriverFactory()
            val script = factory.loadCanonicalTriggerScript()
            factory.executeTriggerScript(driver, script)
            driver.execute(null, "PRAGMA user_version = $EXPECTED_USER_VERSION;", 0)

            return driver
        }

        fun getSqliteVersion(driver: SqlDriver): String {
            val cursor = driver.executeQuery<String>(
                null,
                "SELECT sqlite_version();",
                {
                    it.next()
                    QueryResult.Value(it.getString(0) ?: "UNKNOWN")
                },
                0
            )
            return cursor.value
        }
    }
}
