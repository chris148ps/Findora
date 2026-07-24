@preconcurrency import SQLite3
import Foundation

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public actor SQLiteDatabase {
    private var connection: OpaquePointer?
    private var statusContinuation: AsyncStream<DocumentStatusChange>.Continuation?
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func statusChanges() -> AsyncStream<DocumentStatusChange> {
        let (stream, continuation) = AsyncStream<DocumentStatusChange>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        statusContinuation = continuation
        return stream
    }

    private func publishStatusChange(_ change: DocumentStatusChange) {
        statusContinuation?.yield(change)
    }

    public func initialize() throws {
        guard connection == nil else { return }
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unbekannter SQLite-Fehler"
            if let database { sqlite3_close(database) }
            throw PrivateDocSearchError.database(message)
        }
        connection = database

        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA busy_timeout = 5000")
        try migrate()
    }

    public func saveScan(
        files: [DiscoveredPDF],
        root: URL,
        completedAt: Date = Date()
    ) throws {
        try ensureOpen()
        try transaction {
            let generation = Int64(completedAt.timeIntervalSince1970 * 1_000)
            try execute(
                "CREATE TEMP TABLE IF NOT EXISTS current_scan_paths (absolute_path TEXT PRIMARY KEY)"
            )
            try execute("DELETE FROM current_scan_paths")
            for file in files {
                let discoveredState: ProcessingState = file.isLocallyAvailable ? .discovered : .unavailable
                try execute(
                    "INSERT OR IGNORE INTO current_scan_paths (absolute_path) VALUES (?)",
                    bindings: [.text(file.url.path)]
                )
                try execute(
                    """
                    INSERT INTO processing_jobs
                        (job_key, absolute_path, relative_path, file_name, state, discovered_size,
                         discovered_modified_at, scan_generation, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(job_key) DO UPDATE SET
                        absolute_path = excluded.absolute_path,
                        relative_path = excluded.relative_path,
                        file_name = excluded.file_name,
                        discovered_size = excluded.discovered_size,
                        discovered_modified_at = excluded.discovered_modified_at,
                        scan_generation = excluded.scan_generation,
                        state = CASE
                            WHEN excluded.state = 'unavailable'
                            THEN 'unavailable'
                            WHEN processing_jobs.state IN ('indexed', 'failed')
                                 AND processing_jobs.discovered_size = excluded.discovered_size
                                 AND processing_jobs.discovered_modified_at = excluded.discovered_modified_at
                            THEN processing_jobs.state
                            ELSE 'discovered'
                        END,
                        last_error = excluded.last_error,
                        updated_at = excluded.updated_at
                    """,
                    bindings: [
                        .text(file.id),
                        .text(file.url.path),
                        .text(file.relativePath),
                        .text(file.fileName),
                        .text(discoveredState.rawValue),
                        .integer(file.size),
                        .real(file.modifiedAt.timeIntervalSince1970),
                        .integer(generation),
                        .real(completedAt.timeIntervalSince1970),
                        .real(completedAt.timeIntervalSince1970)
                    ]
                )
                try execute(
                    """
                    UPDATE processing_jobs
                    SET last_stage = state
                    WHERE job_key = ? AND state NOT IN ('indexed', 'failed')
                    """,
                    bindings: [.text(file.id)]
                )
                if let availabilityError = file.availabilityError {
                    try execute(
                        """
                        UPDATE processing_jobs
                        SET last_error = ?
                        WHERE job_key = ?
                        """,
                        bindings: [.text(availabilityError), .text(file.id)]
                    )
                }
            }

            let rootPrefix = root.standardizedFileURL.path + "/"
            try execute(
                """
                UPDATE document_locations
                SET deleted_at = NULL, last_seen_at = ?
                WHERE absolute_path IN (SELECT absolute_path FROM current_scan_paths)
                """,
                bindings: [.real(completedAt.timeIntervalSince1970)]
            )
            try execute(
                """
                UPDATE document_locations
                SET deleted_at = ?
                WHERE substr(absolute_path, 1, length(?)) = ?
                  AND deleted_at IS NULL
                  AND NOT EXISTS (
                      SELECT 1 FROM current_scan_paths p
                      WHERE p.absolute_path = document_locations.absolute_path
                  )
                """,
                bindings: [
                    .real(completedAt.timeIntervalSince1970),
                    .text(rootPrefix),
                    .text(rootPrefix)
                ]
            )
            try execute(
                """
                UPDATE processing_jobs
                SET state = 'retired', last_stage = 'retired',
                    last_error = NULL, updated_at = ?
                WHERE substr(absolute_path, 1, length(?)) = ?
                  AND absolute_path NOT IN (SELECT absolute_path FROM current_scan_paths)
                """,
                bindings: [
                    .real(completedAt.timeIntervalSince1970),
                    .text(rootPrefix),
                    .text(rootPrefix)
                ]
            )

            try setSetting(key: "documentRootPath", value: root.path)
            try setSetting(key: "lastFullScan", value: String(completedAt.timeIntervalSince1970))
            try setSetting(key: "lastScanGeneration", value: String(generation))
        }
        publishStatusChange(.scanCompleted)
    }

    public func pendingFiles(limit: Int = 100) throws -> [DiscoveredPDF] {
        let rows = try query(
            """
            SELECT absolute_path, relative_path, file_name, discovered_size,
                   discovered_modified_at
            FROM processing_jobs
            WHERE state IN ('discovered', 'waitingForStability', 'ocrQueued')
            ORDER BY updated_at ASC
            LIMIT ?
            """,
            bindings: [.integer(Int64(limit))]
        )
        return rows.compactMap { row in
            guard let path = row.string("absolute_path"),
                  let relative = row.string("relative_path"),
                  let name = row.string("file_name"),
                  let size = row.int64("discovered_size"),
                  let modified = row.double("discovered_modified_at") else {
                return nil
            }
            return DiscoveredPDF(
                url: URL(filePath: path),
                relativePath: relative,
                fileName: name,
                size: size,
                modifiedAt: Date(timeIntervalSince1970: modified),
                resourceIdentifier: nil,
                volumeIdentifier: nil
            )
        }
    }

    public func updateJob(path: String, state: ProcessingState, error: String? = nil) throws {
        try execute(
            """
            UPDATE processing_jobs
            SET state = ?, last_error = ?, attempt_count = attempt_count + ?,
                last_stage = CASE WHEN ? = 'failed' THEN last_stage ELSE ? END,
                updated_at = ?
            WHERE job_key = ?
            """,
            bindings: [
                .text(state.rawValue),
                error.map(SQLiteValue.text) ?? .null,
                .integer(state == .failed ? 1 : 0),
                .text(state.rawValue),
                .text(state.rawValue),
                .real(Date().timeIntervalSince1970),
                .text(path)
            ]
        )
        publishStatusChange(.jobChanged)
    }

    public func indexDocument(
        file: DiscoveredPDF,
        hash: String,
        currentFileHash: String? = nil,
        pages: [ExtractedPage],
        chunks: [TextChunk],
        embeddings: [[Float]],
        embeddingModelID: String,
        embeddingModelVersion: String,
        ocrPerformed: Bool,
        pageQualities: [OCRPageQuality] = []
    ) throws -> Int64 {
        guard chunks.count == embeddings.count else {
            throw PrivateDocSearchError.database("Chunk- und Embedding-Anzahl stimmen nicht überein.")
        }

        let indexedDocumentID = try transaction {
            let now = Date().timeIntervalSince1970
            try execute(
                """
                INSERT INTO documents
                    (content_hash, page_count, text_layer_present, ocr_status,
                     last_successful_processing, last_indexed_at, active_version)
                VALUES (?, ?, 1, ?, ?, ?, 1)
                ON CONFLICT(content_hash) DO UPDATE SET
                    page_count = excluded.page_count,
                    text_layer_present = 1,
                    ocr_status = excluded.ocr_status,
                    last_successful_processing = excluded.last_successful_processing,
                    last_indexed_at = excluded.last_indexed_at,
                    active_version = 1
                """,
                bindings: [
                    .text(hash),
                    .integer(Int64(pages.count)),
                    .text(ocrPerformed ? "completed" : "not_required"),
                    .real(now),
                    .real(now)
                ]
            )
            let documentID = try scalarInt64(
                "SELECT id FROM documents WHERE content_hash = ?",
                bindings: [.text(hash)]
            )

            try execute(
                """
                INSERT INTO document_locations
                    (document_id, absolute_path, relative_path, file_name, file_size,
                     modified_at, deleted_at, last_seen_at, current_file_hash)
                VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?)
                ON CONFLICT(absolute_path) DO UPDATE SET
                    document_id = excluded.document_id,
                    relative_path = excluded.relative_path,
                    file_name = excluded.file_name,
                    file_size = excluded.file_size,
                    modified_at = excluded.modified_at,
                    deleted_at = NULL,
                    last_seen_at = excluded.last_seen_at,
                    current_file_hash = excluded.current_file_hash
                """,
                bindings: [
                    .integer(documentID),
                    .text(file.url.path),
                    .text(file.relativePath),
                    .text(file.fileName),
                    .integer(file.size),
                    .real(file.modifiedAt.timeIntervalSince1970),
                    .real(now),
                    .text(currentFileHash ?? hash)
                ]
            )

            let existingChunkCount = try scalarInt64(
                "SELECT COUNT(*) FROM chunks WHERE document_id = ?",
                bindings: [.integer(documentID)]
            )

            if existingChunkCount == 0 {
                try execute("DELETE FROM pages WHERE document_id = ?", bindings: [.integer(documentID)])
                for page in pages {
                    try execute(
                        "INSERT INTO pages (document_id, page_number, text, text_source) VALUES (?, ?, ?, ?)",
                        bindings: [
                            .integer(documentID),
                            .integer(Int64(page.pageNumber)),
                            .text(page.text),
                            .text(ocrPerformed ? "ocr" : "extracted")
                        ]
                    )
                }

                try execute(
                    "DELETE FROM ocr_page_quality WHERE document_id = ?",
                    bindings: [.integer(documentID)]
                )
                for quality in pageQualities {
                    try execute(
                        """
                        INSERT INTO ocr_page_quality
                            (document_id, page_number, mean_confidence, character_count,
                             word_count, unusual_character_count, broken_word_count,
                             recognized_language, is_empty, image_text_ratio, status)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        bindings: [
                            .integer(documentID),
                            .integer(Int64(quality.pageNumber)),
                            quality.meanConfidence.map(SQLiteValue.real) ?? .null,
                            .integer(Int64(quality.characterCount)),
                            .integer(Int64(quality.wordCount)),
                            .integer(Int64(quality.unusualCharacterCount)),
                            .integer(Int64(quality.suspectedBrokenWordCount)),
                            .text(quality.recognizedLanguage),
                            .integer(quality.isEmpty ? 1 : 0),
                            .real(quality.imageToTextRatio),
                            .text(quality.status.rawValue)
                        ]
                    )
                }

                for chunk in chunks {
                    try execute(
                        """
                        INSERT INTO chunks
                            (id, document_id, document_hash, page_number, ordinal, chunk_text,
                             modified_at, indexed_at, embedding_model_id, embedding_model_version)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        bindings: [
                            .text(chunk.id),
                            .integer(documentID),
                            .text(hash),
                            .integer(Int64(chunk.pageNumber)),
                            .integer(Int64(chunk.ordinal)),
                            .text(chunk.text),
                            .real(file.modifiedAt.timeIntervalSince1970),
                            .real(now),
                            .text(embeddingModelID),
                            .text(embeddingModelVersion)
                        ]
                    )
                    try execute(
                        "INSERT INTO chunks_fts (chunk_id, chunk_text) VALUES (?, ?)",
                        bindings: [.text(chunk.id), .text(chunk.text)]
                    )
                }
            } else {
                try execute(
                    """
                    UPDATE chunks
                    SET embedding_model_id = ?, embedding_model_version = ?, indexed_at = ?
                    WHERE document_id = ?
                    """,
                    bindings: [
                        .text(embeddingModelID),
                        .text(embeddingModelVersion),
                        .real(now),
                        .integer(documentID)
                    ]
                )
            }

            for (index, chunk) in chunks.enumerated() {
                try execute(
                    """
                    INSERT INTO chunk_embeddings
                        (chunk_id, model_id, model_version, dimensions, vector)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(chunk_id, model_id, model_version) DO UPDATE SET
                        dimensions = excluded.dimensions,
                        vector = excluded.vector
                    """,
                    bindings: [
                        .text(chunk.id),
                        .text(embeddingModelID),
                        .text(embeddingModelVersion),
                        .integer(Int64(embeddings[index].count)),
                        .blob(Self.encode(vector: embeddings[index]))
                    ]
                )
            }

            try execute(
                """
                UPDATE processing_jobs
                SET state = 'indexed', content_hash = ?,
                    discovered_size = ?, discovered_modified_at = ?,
                    last_stage = 'indexed', last_error = NULL, updated_at = ?
                WHERE job_key = ?
                """,
                bindings: [
                    .text(hash),
                    .integer(file.size),
                    .real(file.modifiedAt.timeIntervalSince1970),
                    .real(now),
                    .text(file.id)
                ]
            )
            return documentID
        }
        publishStatusChange(.documentIndexed)
        return indexedDocumentID
    }

    /// Reuses a fully indexed document by immutable source hash or by the hash of
    /// a safely materialized OCR PDF. Paths and timestamps remain location data.
    public func reuseIndexedDocument(file: DiscoveredPDF, observedHash: String) throws -> Bool {
        let rows = try query(
            """
            SELECT d.id, d.content_hash
            FROM documents d
            WHERE (d.content_hash = ?
                   OR EXISTS (
                       SELECT 1 FROM document_locations known
                       WHERE known.document_id = d.id
                         AND known.current_file_hash = ?
                   ))
              AND EXISTS (SELECT 1 FROM chunks c WHERE c.document_id = d.id)
            LIMIT 1
            """,
            bindings: [.text(observedHash), .text(observedHash)]
        )
        guard let row = rows.first,
              let documentID = row.int64("id"),
              let identityHash = row.string("content_hash") else {
            return false
        }

        try transaction {
            let now = Date().timeIntervalSince1970
            try execute(
                """
                INSERT INTO document_locations
                    (document_id, absolute_path, relative_path, file_name, file_size,
                     modified_at, deleted_at, last_seen_at, current_file_hash)
                VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?)
                ON CONFLICT(absolute_path) DO UPDATE SET
                    document_id = excluded.document_id,
                    relative_path = excluded.relative_path,
                    file_name = excluded.file_name,
                    file_size = excluded.file_size,
                    modified_at = excluded.modified_at,
                    deleted_at = NULL,
                    last_seen_at = excluded.last_seen_at,
                    current_file_hash = excluded.current_file_hash
                """,
                bindings: [
                    .integer(documentID),
                    .text(file.url.path),
                    .text(file.relativePath),
                    .text(file.fileName),
                    .integer(file.size),
                    .real(file.modifiedAt.timeIntervalSince1970),
                    .real(now),
                    .text(observedHash)
                ]
            )
            try execute(
                """
                UPDATE processing_jobs
                SET state = 'indexed', content_hash = ?, discovered_size = ?,
                    discovered_modified_at = ?, last_stage = 'indexed',
                    last_error = NULL, updated_at = ?
                WHERE job_key = ?
                """,
                bindings: [
                    .text(identityHash),
                    .integer(file.size),
                    .real(file.modifiedAt.timeIntervalSince1970),
                    .real(now),
                    .text(file.id)
                ]
            )
        }
        publishStatusChange(.locationsChanged)
        return true
    }

    public func removeDocumentsWithoutActiveLocations() throws {
        try transaction {
            try execute(
                """
                DELETE FROM chunks_fts
                WHERE chunk_id IN (
                    SELECT c.id
                    FROM chunks c
                    WHERE NOT EXISTS (
                        SELECT 1 FROM document_locations l
                        WHERE l.document_id = c.document_id AND l.deleted_at IS NULL
                    )
                )
                """
            )
            try execute(
                """
                DELETE FROM documents
                WHERE NOT EXISTS (
                    SELECT 1 FROM document_locations l
                    WHERE l.document_id = documents.id AND l.deleted_at IS NULL
                )
                """
            )
        }
        publishStatusChange(.locationsChanged)
    }

    public func lexicalSearch(query searchText: String, limit: Int = 40) throws -> [SearchSource] {
        let matchQuery = Self.safeFTSQuery(searchText)
        guard !matchQuery.isEmpty else { return [] }
        let rows = try query(
            """
            SELECT c.document_id, c.id AS chunk_id, c.page_number, c.chunk_text,
                   l.file_name, l.absolute_path, l.relative_path, bm25(chunks_fts) AS rank
            FROM chunks_fts
            JOIN chunks c ON c.id = chunks_fts.chunk_id
            JOIN document_locations l ON l.document_id = c.document_id AND l.deleted_at IS NULL
            WHERE chunks_fts MATCH ?
            ORDER BY rank
            LIMIT ?
            """,
            bindings: [.text(matchQuery), .integer(Int64(limit))]
        )

        return rows.enumerated().compactMap { index, row in
            Self.source(row: row, score: 1.0 / Double(index + 1))
        }
    }

    public func vectorRows(
        modelID: String,
        modelVersion: String
    ) throws -> [(SearchSource, [Float])] {
        let rows = try query(
            """
            SELECT c.document_id, c.id AS chunk_id, c.page_number, c.chunk_text,
                   l.file_name, l.absolute_path, l.relative_path, e.vector
            FROM chunk_embeddings e
            JOIN chunks c ON c.id = e.chunk_id
            JOIN document_locations l ON l.document_id = c.document_id AND l.deleted_at IS NULL
            WHERE e.model_id = ? AND e.model_version = ?
            """,
            bindings: [.text(modelID), .text(modelVersion)]
        )
        return rows.compactMap { row in
            guard let source = Self.source(row: row, score: 0),
                  let data = row.data("vector") else { return nil }
            return (source, Self.decode(vector: data))
        }
    }

    public func embeddingCoverage(
        modelID: String,
        modelVersion: String
    ) throws -> (embeddedChunks: Int, totalChunks: Int) {
        let total = try scalarInt64("SELECT COUNT(*) FROM chunks")
        let embedded = try scalarInt64(
            """
            SELECT COUNT(DISTINCT e.chunk_id)
            FROM chunk_embeddings e
            JOIN chunks c ON c.id = e.chunk_id
            WHERE e.model_id = ? AND e.model_version = ?
            """,
            bindings: [.text(modelID), .text(modelVersion)]
        )
        return (Int(embedded), Int(total))
    }

    public func statistics() throws -> DocumentStatistics {
        let row = try query(
            """
            WITH active_locations AS (
                SELECT * FROM document_locations WHERE deleted_at IS NULL
            ),
            active_documents AS (
                SELECT DISTINCT document_id FROM active_locations
            ),
            active_chunks AS (
                SELECT c.*
                FROM chunks c
                JOIN active_documents d ON d.document_id = c.document_id
            )
            SELECT
                MAX(
                    (SELECT COUNT(*) FROM active_locations),
                    (SELECT COUNT(*) FROM processing_jobs WHERE state != 'retired')
                ) AS total_pdfs,
                (SELECT COUNT(*) FROM processing_jobs WHERE state = 'indexed')
                    AS indexed_pdfs,
                (SELECT COUNT(*) FROM active_locations l
                 JOIN documents d ON d.id = l.document_id
                 WHERE d.text_layer_present = 1) AS searchable_pdfs,
                (SELECT COUNT(*) FROM active_locations l
                 JOIN documents d ON d.id = l.document_id
                 WHERE d.text_layer_present = 0 OR d.ocr_status = 'pending')
                    + (SELECT COUNT(*) FROM processing_jobs
                       WHERE last_stage IN ('ocrQueued', 'ocrRunning')
                         AND content_hash IS NULL)
                    AS ocr_required_pdfs,
                (SELECT COUNT(*) FROM active_locations l
                 JOIN documents d ON d.id = l.document_id
                 WHERE d.ocr_status = 'completed') AS ocr_processed_pdfs,
                (SELECT COUNT(*) FROM processing_jobs
                 WHERE state = 'failed' AND last_stage = 'ocrRunning')
                    AS ocr_failed_pdfs,
                (SELECT COUNT(*) FROM processing_jobs
                 WHERE state IN ('discovered', 'waitingForStability', 'ocrQueued'))
                    AS pending_jobs,
                (SELECT COUNT(*) FROM processing_jobs
                 WHERE state IN ('extracting', 'ocrRunning', 'indexing'))
                    AS processing_jobs,
                (SELECT COUNT(*) FROM processing_jobs WHERE state = 'retired')
                    AS skipped_jobs,
                (SELECT COUNT(*) FROM processing_jobs WHERE state = 'failed')
                    AS failed_jobs,
                (SELECT COUNT(*) FROM active_chunks) AS total_chunks,
                (SELECT COUNT(*) FROM active_chunks c
                 WHERE EXISTS (SELECT 1 FROM chunk_embeddings e WHERE e.chunk_id = c.id))
                    AS embedded_chunks,
                (SELECT COUNT(*) FROM active_chunks c
                 WHERE EXISTS (
                     SELECT 1 FROM chunk_embeddings e
                     WHERE e.chunk_id = c.id AND e.model_id = 'builtin-token-hash'
                 )) AS fallback_embedded_chunks,
                (SELECT COUNT(*) FROM active_chunks c
                 WHERE EXISTS (
                     SELECT 1 FROM chunk_embeddings e
                     WHERE e.chunk_id = c.id AND lower(e.model_id) LIKE '%e5%'
                 )) AS e5_embedded_chunks,
                MAX(
                    0,
                    (SELECT COUNT(*) FROM active_locations)
                    - (SELECT COUNT(*) FROM active_documents)
                ) AS duplicate_locations,
                (SELECT COUNT(*) FROM document_locations WHERE deleted_at IS NOT NULL)
                    + (SELECT COUNT(*) FROM processing_jobs WHERE state = 'unavailable')
                    AS missing_or_moved_files,
                (SELECT COUNT(*) FROM ocr_page_quality q
                 JOIN active_documents d ON d.document_id = q.document_id
                 WHERE q.status = 'good') AS ocr_quality_good,
                (SELECT COUNT(*) FROM ocr_page_quality q
                 JOIN active_documents d ON d.document_id = q.document_id
                 WHERE q.status = 'review') AS ocr_quality_review,
                (SELECT COUNT(*) FROM ocr_page_quality q
                 JOIN active_documents d ON d.document_id = q.document_id
                 WHERE q.status = 'likelyFailed') AS ocr_quality_failed,
                (SELECT COUNT(*) FROM processing_jobs
                 WHERE state IN ('indexed', 'failed')) AS processed_jobs,
                (SELECT COUNT(*) FROM processing_jobs
                 WHERE state NOT IN ('retired', 'unavailable')) AS total_jobs
            """
        ).first
        var result = DocumentStatistics()
        result.totalPDFs = Int(row?.int64("total_pdfs") ?? 0)
        result.indexedPDFs = Int(row?.int64("indexed_pdfs") ?? 0)
        result.searchablePDFs = Int(row?.int64("searchable_pdfs") ?? 0)
        result.withoutTextLayerPDFs = max(0, result.totalPDFs - result.searchablePDFs)
        result.ocrRequiredPDFs = Int(row?.int64("ocr_required_pdfs") ?? 0)
        result.ocrProcessedPDFs = Int(row?.int64("ocr_processed_pdfs") ?? 0)
        result.ocrFailedPDFs = Int(row?.int64("ocr_failed_pdfs") ?? 0)
        result.pendingJobs = Int(row?.int64("pending_jobs") ?? 0)
        result.processingJobs = Int(row?.int64("processing_jobs") ?? 0)
        result.skippedJobs = Int(row?.int64("skipped_jobs") ?? 0)
        result.failedJobs = Int(row?.int64("failed_jobs") ?? 0)
        result.totalChunks = Int(row?.int64("total_chunks") ?? 0)
        result.embeddedChunks = Int(row?.int64("embedded_chunks") ?? 0)
        result.fallbackEmbeddedChunks = Int(row?.int64("fallback_embedded_chunks") ?? 0)
        result.e5EmbeddedChunks = Int(row?.int64("e5_embedded_chunks") ?? 0)
        result.duplicateLocations = Int(row?.int64("duplicate_locations") ?? 0)
        result.missingOrMovedFiles = Int(row?.int64("missing_or_moved_files") ?? 0)
        result.ocrQualityGoodPages = Int(row?.int64("ocr_quality_good") ?? 0)
        result.ocrQualityReviewPages = Int(row?.int64("ocr_quality_review") ?? 0)
        result.ocrQualityFailedPages = Int(row?.int64("ocr_quality_failed") ?? 0)
        result.processedJobs = Int(row?.int64("processed_jobs") ?? 0)
        result.totalJobs = Int(row?.int64("total_jobs") ?? 0)
        result.isPaused = try setting(key: "processingPaused") == "1"
        result.pausedJobs = result.isPaused
            ? result.pendingJobs + result.processingJobs
            : 0

        if let current = try query(
            """
            SELECT state, file_name
            FROM processing_jobs
            WHERE state IN (
                'discovered', 'waitingForStability', 'extracting',
                'ocrQueued', 'ocrRunning', 'indexing'
            )
            ORDER BY
                CASE state
                    WHEN 'indexing' THEN 0
                    WHEN 'ocrRunning' THEN 1
                    WHEN 'extracting' THEN 2
                    ELSE 3
                END,
                updated_at DESC
            LIMIT 1
            """
        ).first {
            result.currentFile = current.string("file_name")
            result.currentStep = result.isPaused
                ? "Pausiert"
                : current.string("state")
                    .flatMap(ProcessingState.init(rawValue:))?
                    .displayName
        }
        if let success = try query(
            """
            SELECT file_name FROM processing_jobs
            WHERE state = 'indexed'
            ORDER BY updated_at DESC LIMIT 1
            """
        ).first?.string("file_name") {
            result.lastSuccessfulStep = "Indexiert: \(success)"
        }
        result.lastProcessingError = try query(
            """
            SELECT message AS last_error
            FROM (
                SELECT last_error AS message, updated_at AS event_time
                FROM processing_jobs
                WHERE state = 'failed' AND last_error IS NOT NULL
                UNION ALL
                SELECT message, created_at AS event_time
                FROM errors
                WHERE resolved_at IS NULL
            )
            ORDER BY event_time DESC
            LIMIT 1
            """
        ).first?.string("last_error")
        if let value = try setting(key: "lastFullScan").flatMap(Double.init) {
            result.lastFullScan = Date(timeIntervalSince1970: value)
        }
        return result
    }

    public func recordError(
        category: String,
        message: String,
        path: String? = nil
    ) throws {
        try execute(
            """
            INSERT INTO errors (category, message, path, created_at, resolved_at)
            VALUES (?, ?, ?, ?, NULL)
            """,
            bindings: [
                .text(category),
                .text(message),
                path.map(SQLiteValue.text) ?? .null,
                .real(Date().timeIntervalSince1970)
            ]
        )
        publishStatusChange(.errorRecorded)
    }

    public func queueFullReindex() throws {
        try execute(
            """
            UPDATE processing_jobs
            SET state = 'discovered', last_stage = 'discovered',
                last_error = NULL, updated_at = ?
            WHERE absolute_path IN (
                SELECT absolute_path FROM document_locations WHERE deleted_at IS NULL
            )
            """,
            bindings: [.real(Date().timeIntervalSince1970)]
        )
        publishStatusChange(.maintenanceCompleted)
    }

    public func storedDocumentTexts() throws -> [StoredDocumentText] {
        let rows = try query(
            """
            SELECT d.id AS document_id, d.content_hash, p.page_number, p.text,
                   COALESCE(MAX(l.modified_at), 0) AS modified_at
            FROM documents d
            JOIN pages p ON p.document_id = d.id
            JOIN document_locations l ON l.document_id = d.id AND l.deleted_at IS NULL
            GROUP BY d.id, d.content_hash, p.page_number, p.text
            ORDER BY d.id, p.page_number
            """
        )
        var order: [Int64] = []
        var values: [Int64: (String, Date, [ExtractedPage])] = [:]
        for row in rows {
            guard let id = row.int64("document_id"),
                  let hash = row.string("content_hash"),
                  let pageNumber = row.int64("page_number"),
                  let text = row.string("text"),
                  let modified = row.double("modified_at") else { continue }
            if values[id] == nil {
                order.append(id)
                values[id] = (hash, Date(timeIntervalSince1970: modified), [])
            }
            values[id]?.2.append(ExtractedPage(pageNumber: Int(pageNumber), text: text))
        }
        return order.compactMap { id in
            guard let value = values[id] else { return nil }
            return StoredDocumentText(
                documentID: id,
                contentHash: value.0,
                modifiedAt: value.1,
                pages: value.2
            )
        }
    }

    public func replaceEntireSearchIndex(
        with indexes: [RebuiltDocumentIndex],
        embeddingModelID: String,
        embeddingModelVersion: String
    ) throws {
        for index in indexes where index.chunks.count != index.embeddings.count {
            throw PrivateDocSearchError.database("Chunk- und Embedding-Anzahl stimmen nicht überein.")
        }
        try transaction {
            let now = Date().timeIntervalSince1970
            try execute("DELETE FROM chunks_fts")
            try execute("DELETE FROM chunk_embeddings")
            try execute("DELETE FROM chunks")
            for index in indexes {
                for (offset, chunk) in index.chunks.enumerated() {
                    try execute(
                        """
                        INSERT INTO chunks
                            (id, document_id, document_hash, page_number, ordinal, chunk_text,
                             modified_at, indexed_at, embedding_model_id, embedding_model_version)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        bindings: [
                            .text(chunk.id),
                            .integer(index.document.documentID),
                            .text(index.document.contentHash),
                            .integer(Int64(chunk.pageNumber)),
                            .integer(Int64(chunk.ordinal)),
                            .text(chunk.text),
                            .real(index.document.modifiedAt.timeIntervalSince1970),
                            .real(now),
                            .text(embeddingModelID),
                            .text(embeddingModelVersion)
                        ]
                    )
                    try execute(
                        "INSERT INTO chunks_fts (chunk_id, chunk_text) VALUES (?, ?)",
                        bindings: [.text(chunk.id), .text(chunk.text)]
                    )
                    try execute(
                        """
                        INSERT INTO chunk_embeddings
                            (chunk_id, model_id, model_version, dimensions, vector)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                        bindings: [
                            .text(chunk.id),
                            .text(embeddingModelID),
                            .text(embeddingModelVersion),
                            .integer(Int64(index.embeddings[offset].count)),
                            .blob(Self.encode(vector: index.embeddings[offset]))
                        ]
                    )
                }
                try execute(
                    "UPDATE documents SET last_indexed_at = ? WHERE id = ?",
                    bindings: [.real(now), .integer(index.document.documentID)]
                )
            }
        }
        publishStatusChange(.embeddingsChanged)
    }

    public func resetOCRData() throws {
        try transaction {
            let now = Date().timeIntervalSince1970
            try execute(
                """
                DELETE FROM chunks_fts
                WHERE chunk_id IN (
                    SELECT c.id FROM chunks c
                    JOIN documents d ON d.id = c.document_id
                    WHERE d.ocr_status = 'completed'
                )
                """
            )
            try execute(
                "DELETE FROM chunks WHERE document_id IN (SELECT id FROM documents WHERE ocr_status = 'completed')"
            )
            try execute(
                "DELETE FROM pages WHERE document_id IN (SELECT id FROM documents WHERE ocr_status = 'completed')"
            )
            try execute(
                "DELETE FROM ocr_page_quality WHERE document_id IN (SELECT id FROM documents WHERE ocr_status = 'completed')"
            )
            try execute(
                """
                UPDATE documents
                SET ocr_status = 'pending', text_layer_present = 0,
                    last_successful_processing = NULL, last_indexed_at = NULL
                WHERE ocr_status = 'completed'
                """
            )
            try execute(
                """
                UPDATE processing_jobs
                SET state = 'discovered', last_stage = 'discovered',
                    last_error = NULL, updated_at = ?
                WHERE absolute_path IN (
                    SELECT absolute_path FROM document_locations WHERE deleted_at IS NULL
                )
                  AND content_hash IN (
                    SELECT content_hash FROM documents WHERE ocr_status = 'pending'
                )
                """,
                bindings: [.real(now)]
            )
        }
        publishStatusChange(.maintenanceCompleted)
    }

    public func deleteDocumentIndex() throws {
        try transaction {
            try execute("DELETE FROM chunks_fts")
            try execute("DELETE FROM processing_jobs")
            try execute("DELETE FROM document_locations")
            try execute("DELETE FROM documents")
            try execute("DELETE FROM errors")
            try execute("DELETE FROM search_history")
        }
        publishStatusChange(.maintenanceCompleted)
    }

    public func repairIndex() throws -> String {
        let integrity = try query("PRAGMA integrity_check").first?.string("integrity_check") ?? "unknown"
        guard integrity == "ok" else {
            throw PrivateDocSearchError.database("SQLite-Integritätsprüfung: \(integrity)")
        }
        let foreignKeys = try query("PRAGMA foreign_key_check")
        guard foreignKeys.isEmpty else {
            throw PrivateDocSearchError.database(
                "SQLite meldet \(foreignKeys.count) Fremdschlüsselverletzungen."
            )
        }
        try transaction {
            let now = Date().timeIntervalSince1970
            try execute("DELETE FROM chunks_fts")
            try execute(
                "INSERT INTO chunks_fts (chunk_id, chunk_text) SELECT id, chunk_text FROM chunks"
            )
            try execute(
                """
                UPDATE processing_jobs
                SET state = 'retired', last_stage = 'retired',
                    last_error = NULL, updated_at = ?
                WHERE NOT EXISTS (
                    SELECT 1 FROM document_locations l
                    WHERE l.absolute_path = processing_jobs.absolute_path
                      AND l.deleted_at IS NULL
                )
                  AND state != 'unavailable'
                """,
                bindings: [.real(now)]
            )
            try execute(
                """
                UPDATE processing_jobs
                SET state = 'discovered', last_stage = 'discovered',
                    last_error = NULL, updated_at = ?
                WHERE absolute_path IN (
                    SELECT l.absolute_path
                    FROM document_locations l
                    WHERE l.deleted_at IS NULL
                      AND NOT EXISTS (
                          SELECT 1 FROM chunks c WHERE c.document_id = l.document_id
                      )
                )
                """,
                bindings: [.real(now)]
            )
        }
        publishStatusChange(.maintenanceCompleted)
        return "SQLite-Integrität und Fremdschlüssel sind in Ordnung; FTS und Jobzustände wurden abgeglichen."
    }

    public func retryFailedJobs() throws {
        try execute(
            """
            UPDATE processing_jobs
            SET state = 'discovered', last_stage = 'discovered',
                last_error = NULL, updated_at = ?
            WHERE state = 'failed'
            """,
            bindings: [.real(Date().timeIntervalSince1970)]
        )
        publishStatusChange(.jobChanged)
    }

    public func recentErrors(limit: Int = 100) throws -> [(Date, String, String, String?)] {
        try query(
            """
            SELECT event_time AS created_at, category, message, path
            FROM (
                SELECT created_at AS event_time, category, message, path
                FROM errors
                UNION ALL
                SELECT updated_at AS event_time,
                       'Verfügbarkeit' AS category,
                       COALESCE(last_error, 'Datei ist derzeit nicht lokal verfügbar.') AS message,
                       absolute_path AS path
                FROM processing_jobs
                WHERE state = 'unavailable'
            )
            ORDER BY event_time DESC
            LIMIT ?
            """,
            bindings: [.integer(Int64(limit))]
        ).compactMap { row in
            guard let timestamp = row.double("created_at"),
                  let category = row.string("category"),
                  let message = row.string("message") else { return nil }
            return (Date(timeIntervalSince1970: timestamp), category, message, row.string("path"))
        }
    }

    public func setting(key: String) throws -> String? {
        try query(
            "SELECT value FROM settings WHERE key = ?",
            bindings: [.text(key)]
        ).first?.string("value")
    }

    public func setSetting(key: String, value: String) throws {
        try execute(
            """
            INSERT INTO settings (key, value, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
            """,
            bindings: [.text(key), .text(value), .real(Date().timeIntervalSince1970)]
        )
    }

    public func setProcessingPaused(_ paused: Bool) throws {
        try setSetting(key: "processingPaused", value: paused ? "1" : "0")
        publishStatusChange(.processingPaused)
    }

    private func migrate() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER PRIMARY KEY,
                applied_at REAL NOT NULL
            )
            """
        )
        let current = try scalarInt64("SELECT COALESCE(MAX(version), 0) FROM schema_migrations")
        if current < 1 {
            try transaction {
                for statement in Self.migration1 {
                    try execute(statement)
                }
                try execute(
                    "INSERT INTO schema_migrations (version, applied_at) VALUES (1, ?)",
                    bindings: [.real(Date().timeIntervalSince1970)]
                )
            }
        }
        if current < 2 {
            try transaction {
                for statement in Self.migration2 {
                    try execute(statement)
                }
                try execute(
                    "INSERT INTO schema_migrations (version, applied_at) VALUES (2, ?)",
                    bindings: [.real(Date().timeIntervalSince1970)]
                )
            }
        }
        if current < 3 {
            try transaction {
                for statement in Self.migration3 {
                    try execute(statement)
                }
                try execute(
                    "INSERT INTO schema_migrations (version, applied_at) VALUES (3, ?)",
                    bindings: [.real(Date().timeIntervalSince1970)]
                )
            }
        }
        if current < 4 {
            try transaction {
                for statement in Self.migration4 {
                    try execute(statement)
                }
                try execute(
                    "INSERT INTO schema_migrations (version, applied_at) VALUES (4, ?)",
                    bindings: [.real(Date().timeIntervalSince1970)]
                )
            }
        }
        if current < 5 {
            try transaction {
                for statement in Self.migration5 {
                    try execute(statement)
                }
                try execute(
                    "INSERT INTO schema_migrations (version, applied_at) VALUES (5, ?)",
                    bindings: [.real(Date().timeIntervalSince1970)]
                )
            }
        }
    }

    private func ensureOpen() throws {
        guard connection != nil else {
            throw PrivateDocSearchError.database("Die Datenbank wurde noch nicht initialisiert.")
        }
    }

    @discardableResult
    private func execute(_ sql: String, bindings: [SQLiteValue] = []) throws -> Int32 {
        try ensureOpen()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw databaseError(sql)
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw databaseError(sql)
        }
        return result
    }

    private func query(_ sql: String, bindings: [SQLiteValue] = []) throws -> [SQLiteRow] {
        try ensureOpen()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw databaseError(sql)
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        var rows: [SQLiteRow] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw databaseError(sql) }
            var values: [String: SQLiteValue] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER:
                    values[name] = .integer(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT:
                    values[name] = .real(sqlite3_column_double(statement, index))
                case SQLITE_TEXT:
                    values[name] = .text(String(cString: sqlite3_column_text(statement, index)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    if let bytes = sqlite3_column_blob(statement, index), count > 0 {
                        values[name] = .blob(Data(bytes: bytes, count: count))
                    } else {
                        values[name] = .blob(Data())
                    }
                default:
                    values[name] = .null
                }
            }
            rows.append(SQLiteRow(values: values))
        }
        return rows
    }

    private func scalarInt64(_ sql: String, bindings: [SQLiteValue] = []) throws -> Int64 {
        try ensureOpen()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw databaseError(sql)
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError(sql) }
        return sqlite3_column_int64(statement, 0)
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            _ = try? execute("ROLLBACK")
            throw error
        }
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null:
                result = sqlite3_bind_null(statement, index)
            case .integer(let value):
                result = sqlite3_bind_int64(statement, index, value)
            case .real(let value):
                result = sqlite3_bind_double(statement, index, value)
            case .text(let value):
                result = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
            case .blob(let data):
                result = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
                }
            }
            guard result == SQLITE_OK else { throw databaseError("Bind") }
        }
    }

    private func databaseError(_ sql: String) -> PrivateDocSearchError {
        let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Unbekannt"
        return .database("\(message) [\(sql.prefix(120))]")
    }

    private static func encode(vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func decode(vector data: Data) -> [Float] {
        data.withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: Float.self))
        }
    }

    private static func safeFTSQuery(_ input: String) -> String {
        let terms = input
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }
            .prefix(12)
        return terms.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }.joined(separator: " OR ")
    }

    private static func source(row: SQLiteRow, score: Double) -> SearchSource? {
        guard let documentID = row.int64("document_id"),
              let chunkID = row.string("chunk_id"),
              let page = row.int64("page_number"),
              let text = row.string("chunk_text"),
              let fileName = row.string("file_name"),
              let absolutePath = row.string("absolute_path"),
              let relativePath = row.string("relative_path") else {
            return nil
        }
        let excerpt = text.count > 480 ? String(text.prefix(477)) + "…" : text
        return SearchSource(
            id: "\(chunkID)|\(absolutePath)",
            documentID: documentID,
            chunkID: chunkID,
            fileName: fileName,
            absolutePath: absolutePath,
            relativePath: relativePath,
            pageNumber: Int(page),
            excerpt: excerpt,
            score: score
        )
    }

    private static let migration1 = [
        """
        CREATE TABLE documents (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            content_hash TEXT NOT NULL UNIQUE,
            page_count INTEGER NOT NULL DEFAULT 0,
            text_layer_present INTEGER NOT NULL DEFAULT 0,
            ocr_status TEXT NOT NULL DEFAULT 'unknown',
            last_successful_processing REAL,
            last_indexed_at REAL,
            active_version INTEGER NOT NULL DEFAULT 1
        )
        """,
        """
        CREATE TABLE document_locations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            document_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            absolute_path TEXT NOT NULL UNIQUE,
            relative_path TEXT NOT NULL,
            file_name TEXT NOT NULL,
            file_size INTEGER NOT NULL,
            modified_at REAL NOT NULL,
            deleted_at REAL,
            last_seen_at REAL NOT NULL
        )
        """,
        """
        CREATE TABLE pages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            document_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            page_number INTEGER NOT NULL,
            text TEXT NOT NULL,
            UNIQUE(document_id, page_number)
        )
        """,
        """
        CREATE TABLE chunks (
            id TEXT PRIMARY KEY,
            document_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            document_hash TEXT NOT NULL,
            page_number INTEGER NOT NULL,
            ordinal INTEGER NOT NULL,
            chunk_text TEXT NOT NULL,
            modified_at REAL NOT NULL,
            indexed_at REAL NOT NULL,
            embedding_model_id TEXT NOT NULL,
            embedding_model_version TEXT NOT NULL
        )
        """,
        "CREATE VIRTUAL TABLE chunks_fts USING fts5(chunk_id UNINDEXED, chunk_text, tokenize='unicode61 remove_diacritics 2')",
        """
        CREATE TABLE chunk_embeddings (
            chunk_id TEXT NOT NULL REFERENCES chunks(id) ON DELETE CASCADE,
            model_id TEXT NOT NULL,
            model_version TEXT NOT NULL,
            dimensions INTEGER NOT NULL,
            vector BLOB NOT NULL,
            PRIMARY KEY(chunk_id, model_id, model_version)
        )
        """,
        """
        CREATE TABLE processing_jobs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            job_key TEXT NOT NULL UNIQUE,
            absolute_path TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            file_name TEXT NOT NULL,
            state TEXT NOT NULL,
            discovered_size INTEGER NOT NULL,
            discovered_modified_at REAL NOT NULL,
            content_hash TEXT,
            scan_generation INTEGER NOT NULL,
            attempt_count INTEGER NOT NULL DEFAULT 0,
            last_error TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        )
        """,
        """
        CREATE TABLE ocr_results (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            document_id INTEGER REFERENCES documents(id) ON DELETE SET NULL,
            input_hash TEXT NOT NULL,
            output_hash TEXT,
            command_version TEXT,
            status TEXT NOT NULL,
            started_at REAL NOT NULL,
            completed_at REAL,
            error_message TEXT
        )
        """,
        """
        CREATE TABLE index_state (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            embedding_model_id TEXT NOT NULL,
            embedding_model_version TEXT NOT NULL,
            chunker_version TEXT NOT NULL,
            state TEXT NOT NULL,
            indexed_chunks INTEGER NOT NULL DEFAULT 0,
            total_chunks INTEGER NOT NULL DEFAULT 0,
            activated_at REAL
        )
        """,
        """
        CREATE TABLE embedding_models (
            id TEXT NOT NULL,
            version TEXT NOT NULL,
            state TEXT NOT NULL,
            installed_path TEXT,
            installed_at REAL,
            PRIMARY KEY(id, version)
        )
        """,
        """
        CREATE TABLE llm_models (
            id TEXT NOT NULL,
            version TEXT NOT NULL,
            state TEXT NOT NULL,
            installed_path TEXT,
            installed_at REAL,
            last_tested_at REAL,
            PRIMARY KEY(id, version)
        )
        """,
        """
        CREATE TABLE model_downloads (
            id TEXT PRIMARY KEY,
            model_id TEXT NOT NULL,
            model_version TEXT NOT NULL,
            state TEXT NOT NULL,
            downloaded_bytes INTEGER NOT NULL DEFAULT 0,
            total_bytes INTEGER NOT NULL DEFAULT 0,
            resume_data BLOB,
            error_message TEXT,
            updated_at REAL NOT NULL
        )
        """,
        """
        CREATE TABLE settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            updated_at REAL NOT NULL
        )
        """,
        """
        CREATE TABLE errors (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            category TEXT NOT NULL,
            message TEXT NOT NULL,
            path TEXT,
            created_at REAL NOT NULL,
            resolved_at REAL
        )
        """,
        """
        CREATE TABLE search_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            query TEXT NOT NULL,
            created_at REAL NOT NULL,
            result_count INTEGER NOT NULL,
            answer_model_id TEXT
        )
        """,
        """
        CREATE TABLE source_bookmarks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            purpose TEXT NOT NULL UNIQUE,
            bookmark_data BLOB NOT NULL,
            display_path TEXT NOT NULL,
            updated_at REAL NOT NULL
        )
        """,
        "CREATE INDEX idx_locations_document ON document_locations(document_id)",
        "CREATE INDEX idx_jobs_state ON processing_jobs(state, updated_at)",
        "CREATE INDEX idx_chunks_document ON chunks(document_id)",
        "CREATE INDEX idx_embeddings_model ON chunk_embeddings(model_id, model_version)"
    ]

    private static let migration2 = [
        "ALTER TABLE document_locations ADD COLUMN current_file_hash TEXT",
        """
        UPDATE document_locations
        SET current_file_hash = (
            SELECT content_hash FROM documents WHERE documents.id = document_locations.document_id
        )
        WHERE current_file_hash IS NULL
        """,
        "CREATE INDEX idx_locations_current_hash ON document_locations(current_file_hash)"
    ]

    private static let migration3 = [
        """
        CREATE TABLE ocr_page_quality (
            document_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            page_number INTEGER NOT NULL,
            mean_confidence REAL,
            character_count INTEGER NOT NULL,
            word_count INTEGER NOT NULL,
            unusual_character_count INTEGER NOT NULL,
            broken_word_count INTEGER NOT NULL,
            recognized_language TEXT NOT NULL,
            is_empty INTEGER NOT NULL,
            image_text_ratio REAL NOT NULL,
            status TEXT NOT NULL,
            PRIMARY KEY(document_id, page_number)
        )
        """,
        "CREATE INDEX idx_ocr_quality_status ON ocr_page_quality(status)"
    ]

    private static let migration4 = [
        "ALTER TABLE pages ADD COLUMN text_source TEXT NOT NULL DEFAULT 'extracted'",
        """
        UPDATE pages
        SET text_source = 'ocr'
        WHERE document_id IN (SELECT id FROM documents WHERE ocr_status = 'completed')
        """
    ]

    private static let migration5 = [
        "ALTER TABLE processing_jobs ADD COLUMN last_stage TEXT NOT NULL DEFAULT 'discovered'",
        """
        UPDATE processing_jobs
        SET last_stage = CASE
            WHEN state = 'failed' THEN 'failed'
            ELSE state
        END
        """
    ]
}

private enum SQLiteValue: Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

private struct SQLiteRow: Sendable {
    let values: [String: SQLiteValue]

    func string(_ key: String) -> String? {
        if case .text(let value) = values[key] { return value }
        return nil
    }

    func int64(_ key: String) -> Int64? {
        if case .integer(let value) = values[key] { return value }
        return nil
    }

    func double(_ key: String) -> Double? {
        if case .real(let value) = values[key] { return value }
        if case .integer(let value) = values[key] { return Double(value) }
        return nil
    }

    func data(_ key: String) -> Data? {
        if case .blob(let value) = values[key] { return value }
        return nil
    }
}
