@preconcurrency import SQLite3
import Foundation

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public actor SQLiteDatabase {
    private var connection: OpaquePointer?
    private var statusContinuation: AsyncStream<DocumentStatusChange>.Continuation?
    public nonisolated let url: URL

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
            throw FindoraError.database(message)
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
        removedDocumentPolicy: RemovedDocumentPolicy = .removeAfterSuccessfulScan,
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
                        content_hash = CASE
                            WHEN processing_jobs.discovered_size = excluded.discovered_size
                                 AND processing_jobs.discovered_modified_at = excluded.discovered_modified_at
                            THEN processing_jobs.content_hash
                            ELSE NULL
                        END,
                        ocr_engine = CASE
                            WHEN processing_jobs.discovered_size = excluded.discovered_size
                                 AND processing_jobs.discovered_modified_at = excluded.discovered_modified_at
                            THEN processing_jobs.ocr_engine
                            ELSE NULL
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
            if removedDocumentPolicy != .keepIndexed {
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
            }
            let missingState = removedDocumentPolicy == .keepIndexed
                ? ProcessingState.unavailable.rawValue
                : ProcessingState.retired.rawValue
            try execute(
                """
                UPDATE processing_jobs
                SET state = ?, last_stage = ?,
                    last_error = ?, updated_at = ?
                WHERE substr(absolute_path, 1, length(?)) = ?
                  AND absolute_path NOT IN (SELECT absolute_path FROM current_scan_paths)
                """,
                bindings: [
                    .text(missingState),
                    .text(missingState),
                    removedDocumentPolicy == .keepIndexed
                        ? .text("Datei fehlt; Index bleibt gemäß Einstellung erhalten.")
                        : .null,
                    .real(completedAt.timeIntervalSince1970),
                    .text(rootPrefix),
                    .text(rootPrefix)
                ]
            )
            if removedDocumentPolicy == .removeAfterSuccessfulScan {
                try execute(
                    """
                    DELETE FROM ocr_page_attempts
                    WHERE NOT EXISTS (
                        SELECT 1
                        FROM processing_jobs j
                        WHERE j.job_key = ocr_page_attempts.absolute_path
                          AND j.state NOT IN ('retired', 'unavailable')
                          AND (
                              j.content_hash IS NULL
                              OR j.content_hash = ocr_page_attempts.original_hash
                          )
                    )
                    """
                )
                try execute(
                    """
                    DELETE FROM page_content_analysis
                    WHERE NOT EXISTS (
                        SELECT 1
                        FROM processing_jobs j
                        WHERE j.job_key = page_content_analysis.absolute_path
                          AND j.state NOT IN ('retired', 'unavailable')
                          AND (
                              j.content_hash IS NULL
                              OR j.content_hash = page_content_analysis.original_hash
                          )
                    )
                    """
                )
            }

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

    public func updateJob(
        path: String,
        state: ProcessingState,
        error: String? = nil,
        ocrEngine: OCREngine? = nil
    ) throws {
        try execute(
            """
            UPDATE processing_jobs
            SET state = ?, last_error = ?, attempt_count = attempt_count + ?,
                last_stage = CASE WHEN ? = 'failed' THEN last_stage ELSE ? END,
                ocr_engine = COALESCE(?, ocr_engine),
                updated_at = ?
            WHERE job_key = ?
            """,
            bindings: [
                .text(state.rawValue),
                error.map(SQLiteValue.text) ?? .null,
                .integer(state == .failed ? 1 : 0),
                .text(state.rawValue),
                .text(state.rawValue),
                ocrEngine.map { .text($0.rawValue) } ?? .null,
                .real(Date().timeIntervalSince1970),
                .text(path)
            ]
        )
        publishStatusChange(.jobChanged)
    }

    public func updateOCRRetryProgress(
        path: String,
        attempt: Int,
        total: Int,
        strategy: String?
    ) throws {
        try execute(
            """
            UPDATE processing_jobs
            SET ocr_attempt_current = ?, ocr_attempt_total = ?,
                ocr_strategy = ?, updated_at = ?
            WHERE job_key = ?
            """,
            bindings: [
                .integer(Int64(attempt)),
                .integer(Int64(total)),
                strategy.map(SQLiteValue.text) ?? .null,
                .real(Date().timeIntervalSince1970),
                .text(path)
            ]
        )
        publishStatusChange(.jobChanged)
    }

    public func saveOCRAttempts(
        path: String,
        originalHash: String,
        attempts: [OCRAttemptRecord],
        bestStrategyByPage _: [Int: OCRRetryStrategy]
    ) throws {
        try transaction {
            let attemptedPages = Set(attempts.map(\.pageNumber))
            for pageNumber in attemptedPages {
                try execute(
                    """
                    UPDATE ocr_page_attempts
                    SET is_best = 0
                    WHERE absolute_path = ? AND original_hash = ? AND page_number = ?
                    """,
                    bindings: [
                        .text(path),
                        .text(originalHash),
                        .integer(Int64(pageNumber))
                    ]
                )
            }
            for attempt in attempts {
                try execute(
                    """
                    DELETE FROM ocr_page_attempts
                    WHERE absolute_path = ? AND original_hash = ?
                      AND page_number = ? AND strategy_id = ?
                    """,
                    bindings: [
                        .text(path),
                        .text(originalHash),
                        .integer(Int64(attempt.pageNumber)),
                        .text(attempt.strategy.id)
                    ]
                )
            }
            for attempt in attempts {
                let duration = attempt.duration.components
                let seconds = Double(duration.seconds)
                    + Double(duration.attoseconds) / 1_000_000_000_000_000_000
                try execute(
                    """
                    INSERT INTO ocr_page_attempts (
                        absolute_path, original_hash, page_number, strategy_id,
                        strategy_name, engine, preprocessing, recognized_text,
                        quality_score, quality_status, character_count, word_count,
                        mean_confidence, recognized_language, duration_seconds,
                        is_best, completed_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(path),
                        .text(originalHash),
                        .integer(Int64(attempt.pageNumber)),
                        .text(attempt.strategy.id),
                        .text(attempt.strategy.displayName),
                        .text(attempt.engine.rawValue),
                        .text(attempt.strategy.preprocessing),
                        .text(attempt.text),
                        .real(attempt.qualityScore),
                        .text(attempt.quality.status.rawValue),
                        .integer(Int64(attempt.quality.characterCount)),
                        .integer(Int64(attempt.quality.wordCount)),
                        attempt.quality.meanConfidence.map(SQLiteValue.real) ?? .null,
                        .text(attempt.quality.recognizedLanguage),
                        .real(seconds),
                        .integer(0),
                        .real(attempt.completedAt.timeIntervalSince1970)
                    ]
                )
            }
            for pageNumber in attemptedPages {
                try execute(
                    """
                    UPDATE ocr_page_attempts
                    SET is_best = CASE
                        WHEN id = (
                            SELECT id FROM ocr_page_attempts
                            WHERE absolute_path = ? AND original_hash = ?
                              AND page_number = ?
                            ORDER BY quality_score DESC, completed_at DESC
                            LIMIT 1
                        ) THEN 1 ELSE 0 END
                    WHERE absolute_path = ? AND original_hash = ? AND page_number = ?
                    """,
                    bindings: [
                        .text(path),
                        .text(originalHash),
                        .integer(Int64(pageNumber)),
                        .text(path),
                        .text(originalHash),
                        .integer(Int64(pageNumber))
                    ]
                )
            }
        }
        publishStatusChange(.maintenanceCompleted)
    }

    public func applyOCRPageStatuses(
        path: String,
        acceptedPageNumbers: Set<Int>,
        attemptedPageNumbers: Set<Int>,
        pagesWithAnyText: Set<Int>
    ) throws {
        try transaction {
            for page in attemptedPageNumbers {
                let status: PageContentStatus
                if acceptedPageNumbers.contains(page) {
                    status = .contentDetected
                } else if pagesWithAnyText.contains(page) {
                    status = .needsOCRReview
                } else {
                    status = .ocrNoResult
                }
                try execute(
                    """
                    UPDATE page_content_analysis
                    SET status = ?, updated_at = ?
                    WHERE absolute_path = ? AND page_number = ?
                      AND status != 'safelyEmpty'
                      AND status NOT IN ('manuallyCorrectedText', 'manuallyEnteredText')
                    """,
                    bindings: [
                        .text(status.rawValue),
                        .real(Date().timeIntervalSince1970),
                        .text(path),
                        .integer(Int64(page))
                    ]
                )
            }
        }
        publishStatusChange(.maintenanceCompleted)
    }

    public func updateObservedHash(path: String, hash: String) throws {
        try transaction {
            try execute(
                """
                UPDATE processing_jobs
                SET content_hash = ?, updated_at = ?
                WHERE job_key = ?
                """,
                bindings: [
                    .text(hash),
                    .real(Date().timeIntervalSince1970),
                    .text(path)
                ]
            )
            try execute(
                """
                DELETE FROM ocr_page_attempts
                WHERE absolute_path = ? AND original_hash != ?
                """,
                bindings: [.text(path), .text(hash)]
            )
            try execute(
                """
                DELETE FROM page_content_analysis
                WHERE absolute_path = ? AND original_hash != ?
                """,
                bindings: [.text(path), .text(hash)]
            )
        }
        publishStatusChange(.jobChanged)
    }

    public func replacePageContentAnalyses(
        path: String,
        originalHash: String,
        analyses: [PageContentAnalysis]
    ) throws {
        let existingRows = try query(
            """
            SELECT page_number, original_hash, user_decision,
                   decision_at, decision_source
            FROM page_content_analysis
            WHERE absolute_path = ?
            """,
            bindings: [.text(path)]
        )
        let existingDecisions = Dictionary(uniqueKeysWithValues: existingRows.compactMap {
            row -> (Int, (PageReviewDecision, Double?, String?))? in
            guard row.string("original_hash") == originalHash,
                  let page = row.int64("page_number"),
                  let rawDecision = row.string("user_decision"),
                  let decision = PageReviewDecision(rawValue: rawDecision) else {
                return nil
            }
            return (
                Int(page),
                (decision, row.double("decision_at"), row.string("decision_source"))
            )
        })
        try transaction {
            try execute(
                "DELETE FROM page_content_analysis WHERE absolute_path = ?",
                bindings: [.text(path)]
            )
            let now = Date().timeIntervalSince1970
            for analysis in analyses {
                let metrics = analysis.metrics
                try execute(
                    """
                    INSERT INTO page_content_analysis (
                        absolute_path, original_hash, page_number, page_count,
                        status, confidence, reason, render_succeeded, pixel_width,
                        pixel_height, white_ratio, dark_pixel_ratio, variance,
                        edge_ratio, contrast, character_count, word_count,
                        ocr_confidence, embedded_image_count, annotation_count,
                        has_small_text, user_decision, decision_at,
                        decision_source, updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(path),
                        .text(originalHash),
                        .integer(Int64(analysis.pageNumber)),
                        .integer(Int64(analysis.pageCount)),
                        .text(analysis.status.rawValue),
                        .real(analysis.confidence),
                        .text(analysis.reason),
                        .integer(metrics.renderSucceeded ? 1 : 0),
                        .integer(Int64(metrics.pixelWidth)),
                        .integer(Int64(metrics.pixelHeight)),
                        .real(metrics.whiteRatio),
                        .real(metrics.darkPixelRatio),
                        .real(metrics.variance),
                        .real(metrics.edgeRatio),
                        .real(metrics.contrast),
                        .integer(Int64(metrics.characterCount)),
                        .integer(Int64(metrics.wordCount)),
                        metrics.ocrConfidence.map(SQLiteValue.real) ?? .null,
                        .integer(Int64(metrics.embeddedImageCount)),
                        .integer(Int64(metrics.annotationCount)),
                        .integer(metrics.hasSmallText ? 1 : 0),
                        .text(
                            (existingDecisions[analysis.pageNumber]?.0 ?? .undecided).rawValue
                        ),
                        existingDecisions[analysis.pageNumber]?.1
                            .map(SQLiteValue.real) ?? .null,
                        existingDecisions[analysis.pageNumber]?.2
                            .map(SQLiteValue.text) ?? .null,
                        .real(now)
                    ]
                )
            }
        }
        publishStatusChange(.maintenanceCompleted)
    }

    public func copyPageContentAnalyses(
        originalHash: String,
        toPath path: String
    ) throws {
        let exists = try scalarInt64(
            """
            SELECT COUNT(*) FROM page_content_analysis
            WHERE absolute_path = ? AND original_hash = ?
            """,
            bindings: [.text(path), .text(originalHash)]
        )
        guard exists == 0 else { return }
        guard let sourcePath = try query(
            """
            SELECT absolute_path
            FROM page_content_analysis
            WHERE original_hash = ?
            ORDER BY updated_at DESC
            LIMIT 1
            """,
            bindings: [.text(originalHash)]
        ).first?.string("absolute_path") else { return }
        try execute(
            """
            INSERT INTO page_content_analysis (
                absolute_path, original_hash, page_number, page_count,
                status, confidence, reason, render_succeeded, pixel_width,
                pixel_height, white_ratio, dark_pixel_ratio, variance,
                edge_ratio, contrast, character_count, word_count,
                ocr_confidence, embedded_image_count, annotation_count,
                has_small_text, user_decision, updated_at
            )
            SELECT ?, original_hash, page_number, page_count,
                   status, confidence, reason, render_succeeded, pixel_width,
                   pixel_height, white_ratio, dark_pixel_ratio, variance,
                   edge_ratio, contrast, character_count, word_count,
                   ocr_confidence, embedded_image_count, annotation_count,
                   has_small_text, 'undecided', ?
            FROM page_content_analysis
            WHERE absolute_path = ? AND original_hash = ?
            """,
            bindings: [
                .text(path),
                .real(Date().timeIntervalSince1970),
                .text(sourcePath),
                .text(originalHash)
            ]
        )
        publishStatusChange(.maintenanceCompleted)
    }

    public func setPageReviewDecision(
        path: String,
        pageNumber: Int,
        decision: PageReviewDecision
    ) throws {
        try execute(
            """
            UPDATE page_content_analysis
            SET user_decision = ?, decision_at = ?,
                decision_source = ?, updated_at = ?
            WHERE absolute_path = ? AND page_number = ?
            """,
            bindings: [
                .text(decision.rawValue),
                .real(Date().timeIntervalSince1970),
                decision == .undecided
                    ? .null
                    : .text("manuelle Prüfung"),
                .real(Date().timeIntervalSince1970),
                .text(path),
                .integer(Int64(pageNumber))
            ]
        )
        publishStatusChange(.maintenanceCompleted)
    }

    public func resetPageReviewDecision(path: String, pageNumber: Int) throws {
        try execute(
            """
            UPDATE page_content_analysis
            SET user_decision = 'undecided', decision_at = NULL,
                decision_source = NULL, updated_at = ?
            WHERE absolute_path = ? AND page_number = ?
            """,
            bindings: [
                .real(Date().timeIntervalSince1970),
                .text(path),
                .integer(Int64(pageNumber))
            ]
        )
        publishStatusChange(.maintenanceCompleted)
    }

    public func emptyPageCandidates() throws -> [EmptyPageCandidate] {
        let rows = try query(
            """
            SELECT a.*, j.relative_path, j.file_name
            FROM page_content_analysis a
            JOIN processing_jobs j ON j.job_key = a.absolute_path
            WHERE j.state NOT IN ('retired', 'unavailable')
              AND j.content_hash = a.original_hash
              AND a.status IN ('unreviewed', 'safelyEmpty', 'probablyEmpty')
              AND a.user_decision NOT IN ('notEmpty', 'excluded')
            ORDER BY j.file_name, a.page_number
            """
        )
        return rows.compactMap(Self.emptyPageCandidate)
    }

    public func emptyPDFCandidates() throws -> [EmptyPDFCandidate] {
        let rows = try query(
            """
            SELECT a.absolute_path, j.relative_path, j.file_name,
                   a.original_hash, MAX(a.page_count) AS page_count,
                   MIN(a.confidence) AS confidence,
                   COUNT(*) AS analyzed_pages,
                   SUM(CASE WHEN a.status IN ('safelyEmpty', 'probablyEmpty')
                                 AND a.user_decision = 'confirmedEmpty'
                            THEN 1 ELSE 0 END) AS empty_pages
            FROM page_content_analysis a
            JOIN processing_jobs j ON j.job_key = a.absolute_path
            WHERE j.state NOT IN ('retired', 'unavailable')
              AND j.content_hash = a.original_hash
            GROUP BY a.absolute_path, j.relative_path, j.file_name, a.original_hash
            HAVING analyzed_pages = page_count AND empty_pages = page_count
            ORDER BY j.file_name
            """
        )
        return rows.compactMap { row in
            guard let path = row.string("absolute_path"),
                  let relative = row.string("relative_path"),
                  let name = row.string("file_name"),
                  let hash = row.string("original_hash"),
                  let count = row.int64("page_count"),
                  let confidence = row.double("confidence") else { return nil }
            return EmptyPDFCandidate(
                absolutePath: path,
                relativePath: relative,
                fileName: name,
                originalHash: hash,
                pageCount: Int(count),
                confidence: confidence
            )
        }
    }

    public func ocrReviewCandidates() throws -> [OCRReviewCandidate] {
        let pageRows = try query(
            """
            SELECT a.absolute_path, j.relative_path, j.file_name,
                   a.original_hash, a.page_number, a.page_count,
                   a.status, a.user_decision,
                   COALESCE(p.text, '') AS current_text,
                   p.original_ocr_text,
                   COALESCE(p.text_kind, 'automatic') AS text_kind
            FROM page_content_analysis a
            JOIN processing_jobs j ON j.job_key = a.absolute_path
            LEFT JOIN documents d ON d.content_hash = j.content_hash
            LEFT JOIN pages p
              ON p.document_id = d.id AND p.page_number = a.page_number
            WHERE j.state NOT IN ('retired', 'unavailable')
              AND j.content_hash = a.original_hash
              AND (
                  a.status IN (
                      'imageWithoutRecognizedText', 'needsOCRReview',
                      'ocrNoResult', 'technicalReviewError'
                  )
                  OR a.user_decision = 'notEmpty'
              )
              AND a.user_decision != 'excluded'
            ORDER BY j.file_name, a.page_number
            """
        )
        let attemptRows = try query(
            """
            SELECT absolute_path, original_hash, page_number, strategy_id,
                   strategy_name, engine, preprocessing, recognized_text,
                   quality_score, quality_status, character_count, word_count,
                   mean_confidence, recognized_language, duration_seconds, is_best
            FROM ocr_page_attempts
            ORDER BY absolute_path, page_number, quality_score DESC
            """
        )
        var attempts: [String: [OCRVariantSummary]] = [:]
        for row in attemptRows {
            guard let path = row.string("absolute_path"),
                  let hash = row.string("original_hash"),
                  let page = row.int64("page_number"),
                  let strategyID = row.string("strategy_id"),
                  let strategyName = row.string("strategy_name"),
                  let engineRaw = row.string("engine"),
                  let engine = OCREngine(rawValue: engineRaw),
                  let preprocessing = row.string("preprocessing"),
                  let text = row.string("recognized_text"),
                  let score = row.double("quality_score"),
                  let qualityRaw = row.string("quality_status"),
                  let quality = OCRQualityStatus(rawValue: qualityRaw),
                  let characters = row.int64("character_count"),
                  let words = row.int64("word_count"),
                  let language = row.string("recognized_language"),
                  let duration = row.double("duration_seconds"),
                  let isBest = row.int64("is_best") else { continue }
            let key = "\(path)#\(hash)#\(page)"
            attempts[key, default: []].append(
                OCRVariantSummary(
                    pageNumber: Int(page),
                    strategyID: strategyID,
                    strategyName: strategyName,
                    engine: engine,
                    preprocessing: preprocessing,
                    text: text,
                    qualityScore: score,
                    qualityStatus: quality,
                    characterCount: Int(characters),
                    wordCount: Int(words),
                    meanConfidence: row.double("mean_confidence"),
                    recognizedLanguage: language,
                    durationSeconds: duration,
                    isBest: isBest == 1
                )
            )
        }
        return pageRows.compactMap { row in
            guard let path = row.string("absolute_path"),
                  let relative = row.string("relative_path"),
                  let name = row.string("file_name"),
                  let hash = row.string("original_hash"),
                  let page = row.int64("page_number"),
                  let pageCount = row.int64("page_count"),
                  let statusRaw = row.string("status"),
                  let status = PageContentStatus(rawValue: statusRaw),
                  let decisionRaw = row.string("user_decision"),
                  let decision = PageReviewDecision(rawValue: decisionRaw),
                  let currentText = row.string("current_text"),
                  let kindRaw = row.string("text_kind"),
                  let kind = PageTextKind(rawValue: kindRaw) else { return nil }
            return OCRReviewCandidate(
                absolutePath: path,
                relativePath: relative,
                fileName: name,
                originalHash: hash,
                pageNumber: Int(page),
                pageCount: Int(pageCount),
                status: status,
                decision: decision,
                currentText: currentText,
                originalOCRText: row.string("original_ocr_text"),
                textKind: kind,
                variants: attempts["\(path)#\(hash)#\(page)"] ?? []
            )
        }
    }

    public func missingFileCandidates() throws -> [MissingFileCandidate] {
        let rows = try query(
            """
            SELECT absolute_path, relative_path, file_name, state, last_error
            FROM processing_jobs
            WHERE state IN ('unavailable', 'retired')
            ORDER BY file_name, absolute_path
            """
        )
        return rows.compactMap { row in
            guard let path = row.string("absolute_path"),
                  let relative = row.string("relative_path"),
                  let name = row.string("file_name"),
                  let state = row.string("state") else { return nil }
            let message = row.string("last_error")
            let normalized = (message ?? "").lowercased()
            let reason: MissingFileReason
            if normalized.contains("icloud") || normalized.contains("nicht lokal") {
                reason = .cloudUnavailable
            } else if normalized.contains("berechtigung")
                        || normalized.contains("zugriff")
                        || normalized.contains("permission") {
                reason = .accessDenied
            } else if state == "retired" {
                reason = .deleted
            } else {
                reason = .moved
            }
            return MissingFileCandidate(
                absolutePath: path,
                relativePath: relative,
                fileName: name,
                reason: reason,
                message: message
            )
        }
    }

    public func manualPageTexts(path: String) throws -> [StoredManualPageText] {
        try query(
            """
            SELECT p.page_number, p.text, p.text_kind, p.original_ocr_text
            FROM pages p
            JOIN document_locations l ON l.document_id = p.document_id
            WHERE l.absolute_path = ? AND l.deleted_at IS NULL
              AND p.text_kind IN ('manuallyCorrected', 'manuallyEntered')
            ORDER BY p.page_number
            """,
            bindings: [.text(path)]
        ).compactMap { row in
            guard let page = row.int64("page_number"),
                  let text = row.string("text"),
                  let rawKind = row.string("text_kind"),
                  let kind = PageTextKind(rawValue: rawKind) else { return nil }
            return StoredManualPageText(
                pageNumber: Int(page),
                text: text,
                kind: kind,
                originalOCRText: row.string("original_ocr_text")
            )
        }
    }

    public func storedDocumentText(path: String) throws -> StoredDocumentText? {
        guard let row = try query(
            """
            SELECT d.id, d.content_hash, l.current_file_hash, l.modified_at
            FROM document_locations l
            JOIN documents d ON d.id = l.document_id
            WHERE l.absolute_path = ? AND l.deleted_at IS NULL
            LIMIT 1
            """,
            bindings: [.text(path)]
        ).first,
        let documentID = row.int64("id"),
        let hash = row.string("content_hash"),
        let modified = row.double("modified_at") else { return nil }
        let pages = try query(
            """
            SELECT page_number, text
            FROM pages
            WHERE document_id = ?
            ORDER BY page_number
            """,
            bindings: [.integer(documentID)]
        ).compactMap { page -> ExtractedPage? in
            guard let number = page.int64("page_number"),
                  let text = page.string("text") else { return nil }
            return ExtractedPage(pageNumber: Int(number), text: text)
        }
        return StoredDocumentText(
            documentID: documentID,
            contentHash: hash,
            currentFileHash: row.string("current_file_hash"),
            modifiedAt: Date(timeIntervalSince1970: modified),
            pages: pages
        )
    }

    public func replacePageTextAndIndex(
        path: String,
        pageNumber: Int,
        text: String,
        textKind: PageTextKind,
        chunks: [TextChunk],
        embeddings: [[Float]],
        embeddingModelID: String,
        embeddingModelVersion: String
    ) throws {
        guard chunks.count == embeddings.count else {
            throw FindoraError.database(
                "Chunk- und Embedding-Anzahl stimmen nicht überein."
            )
        }
        try transaction {
            let documentID = try scalarInt64(
                """
                SELECT document_id FROM document_locations
                WHERE absolute_path = ? AND deleted_at IS NULL
                """,
                bindings: [.text(path)]
            )
            let oldChunkRows = try query(
                """
                SELECT id FROM chunks
                WHERE document_id = ? AND page_number = ?
                """,
                bindings: [
                    .integer(documentID),
                    .integer(Int64(pageNumber))
                ]
            )
            for row in oldChunkRows {
                if let id = row.string("id") {
                    try execute(
                        "DELETE FROM chunks_fts WHERE chunk_id = ?",
                        bindings: [.text(id)]
                    )
                }
            }
            try execute(
                "DELETE FROM chunks WHERE document_id = ? AND page_number = ?",
                bindings: [.integer(documentID), .integer(Int64(pageNumber))]
            )
            try execute(
                """
                UPDATE pages
                SET original_ocr_text = CASE
                        WHEN ? != 'automatic'
                        THEN COALESCE(original_ocr_text, text)
                        ELSE original_ocr_text
                    END,
                    text = ?, text_source = ?, text_kind = ?
                WHERE document_id = ? AND page_number = ?
                """,
                bindings: [
                    .text(textKind.rawValue),
                    .text(text),
                    .text(textKind == .automatic ? "ocr" : "manual"),
                    .text(textKind.rawValue),
                    .integer(documentID),
                    .integer(Int64(pageNumber))
                ]
            )
            let now = Date().timeIntervalSince1970
            for (index, chunk) in chunks.enumerated() {
                try execute(
                    """
                    INSERT INTO chunks (
                        id, document_id, document_hash, page_number, ordinal,
                        chunk_text, modified_at, indexed_at,
                        embedding_model_id, embedding_model_version
                    )
                    SELECT ?, ?, content_hash, ?, ?, ?, ?, ?, ?, ?
                    FROM documents WHERE id = ?
                    """,
                    bindings: [
                        .text(chunk.id),
                        .integer(documentID),
                        .integer(Int64(pageNumber)),
                        .integer(Int64(chunk.ordinal)),
                        .text(chunk.text),
                        .real(now),
                        .real(now),
                        .text(embeddingModelID),
                        .text(embeddingModelVersion),
                        .integer(documentID)
                    ]
                )
                try execute(
                    "INSERT INTO chunks_fts (chunk_id, chunk_text) VALUES (?, ?)",
                    bindings: [.text(chunk.id), .text(chunk.text)]
                )
                try execute(
                    """
                    INSERT INTO chunk_embeddings (
                        chunk_id, model_id, model_version, dimensions, vector
                    ) VALUES (?, ?, ?, ?, ?)
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
            let status: PageContentStatus = switch textKind {
            case .automatic:
                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? .ocrNoResult
                    : .contentDetected
            case .manuallyCorrected: .manuallyCorrectedText
            case .manuallyEntered: .manuallyEnteredText
            }
            try execute(
                """
                UPDATE page_content_analysis
                SET status = ?, user_decision = 'notEmpty',
                    decision_at = ?, decision_source = 'manuelle Prüfung',
                    updated_at = ?
                WHERE absolute_path = ? AND page_number = ?
                """,
                bindings: [
                    .text(status.rawValue),
                    .real(now),
                    .real(now),
                    .text(path),
                    .integer(Int64(pageNumber))
                ]
            )
            try execute(
                "UPDATE documents SET last_indexed_at = ? WHERE id = ?",
                bindings: [.real(now), .integer(documentID)]
            )
        }
        publishStatusChange(.documentIndexed)
    }

    public func duplicateGroups() throws -> [DuplicateGroup] {
        let rows = try query(
            """
            SELECT content_hash, absolute_path, relative_path, file_name,
                   discovered_modified_at, discovered_size
            FROM processing_jobs
            WHERE state NOT IN ('retired', 'unavailable')
              AND content_hash IS NOT NULL
              AND content_hash IN (
                  SELECT content_hash
                  FROM processing_jobs
                  WHERE state NOT IN ('retired', 'unavailable')
                    AND content_hash IS NOT NULL
                  GROUP BY content_hash
                  HAVING COUNT(*) > 1
              )
            ORDER BY content_hash, absolute_path
            """
        )
        var grouped: [String: [DuplicateLocation]] = [:]
        for row in rows {
            guard let hash = row.string("content_hash"),
                  let path = row.string("absolute_path"),
                  let relative = row.string("relative_path"),
                  let name = row.string("file_name"),
                  let modified = row.double("discovered_modified_at"),
                  let size = row.int64("discovered_size") else { continue }
            grouped[hash, default: []].append(
                DuplicateLocation(
                    absolutePath: path,
                    relativePath: relative,
                    fileName: name,
                    modifiedAt: Date(timeIntervalSince1970: modified),
                    fileSize: size
                )
            )
        }
        return grouped.sorted(by: { $0.key < $1.key }).map {
            DuplicateGroup(contentHash: $0.key, locations: $0.value)
        }
    }

    public func filesMissingPageContentAnalysis() throws -> [(path: String, hash: String)] {
        try query(
            """
            SELECT absolute_path, content_hash
            FROM processing_jobs j
            WHERE j.state = 'indexed'
              AND j.content_hash IS NOT NULL
              AND NOT EXISTS (
                  SELECT 1 FROM page_content_analysis a
                  WHERE a.absolute_path = j.absolute_path
                    AND a.original_hash = j.content_hash
              )
            ORDER BY updated_at DESC
            """
        ).compactMap { row in
            guard let path = row.string("absolute_path"),
                  let hash = row.string("content_hash") else { return nil }
            return (path, hash)
        }
    }

    public func markPathsRemoved(_ paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try transaction {
            let now = Date().timeIntervalSince1970
            for path in paths {
                try execute(
                    """
                    UPDATE processing_jobs
                    SET state = 'retired', last_stage = 'retired',
                        last_error = NULL, updated_at = ?
                    WHERE job_key = ?
                    """,
                    bindings: [.real(now), .text(path)]
                )
                try execute(
                    """
                    UPDATE document_locations
                    SET deleted_at = ?
                    WHERE absolute_path = ? AND deleted_at IS NULL
                    """,
                    bindings: [.real(now), .text(path)]
                )
                try execute(
                    "DELETE FROM page_content_analysis WHERE absolute_path = ?",
                    bindings: [.text(path)]
                )
            }
            try removeOrphanedDocumentsInTransaction()
        }
        publishStatusChange(.maintenanceCompleted)
    }

    public func markPathForReindex(
        path: String,
        size: Int64,
        modifiedAt: Date
    ) throws {
        try transaction {
            let now = Date().timeIntervalSince1970
            try execute(
                """
                UPDATE processing_jobs
                SET state = 'discovered', last_stage = 'discovered',
                    content_hash = NULL, discovered_size = ?,
                    discovered_modified_at = ?, last_error = NULL, updated_at = ?
                WHERE job_key = ?
                """,
                bindings: [
                    .integer(size),
                    .real(modifiedAt.timeIntervalSince1970),
                    .real(now),
                    .text(path)
                ]
            )
            try execute(
                """
                UPDATE document_locations
                SET deleted_at = ?
                WHERE absolute_path = ? AND deleted_at IS NULL
                """,
                bindings: [.real(now), .text(path)]
            )
            try execute(
                "DELETE FROM page_content_analysis WHERE absolute_path = ?",
                bindings: [.text(path)]
            )
            try removeOrphanedDocumentsInTransaction()
        }
        publishStatusChange(.maintenanceCompleted)
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
        ocrPageNumbers: Set<Int>? = nil,
        pageQualities: [OCRPageQuality] = [],
        textLayerPresent: Bool = true,
        manualPageTexts: [Int: StoredManualPageText] = [:]
    ) throws -> Int64 {
        guard chunks.count == embeddings.count else {
            throw FindoraError.database("Chunk- und Embedding-Anzahl stimmen nicht überein.")
        }

        let indexedDocumentID = try transaction {
            let now = Date().timeIntervalSince1970
            try execute(
                """
                INSERT INTO documents
                    (content_hash, page_count, text_layer_present, ocr_status,
                     last_successful_processing, last_indexed_at, active_version,
                     content_type)
                VALUES (?, ?, ?, ?, ?, ?, 1, 'pdf')
                ON CONFLICT(content_hash) DO UPDATE SET
                    page_count = excluded.page_count,
                    text_layer_present = excluded.text_layer_present,
                    ocr_status = excluded.ocr_status,
                    last_successful_processing = excluded.last_successful_processing,
                    last_indexed_at = excluded.last_indexed_at,
                    active_version = 1,
                    content_type = 'pdf'
                """,
                bindings: [
                    .text(hash),
                    .integer(Int64(pages.count)),
                    .integer(textLayerPresent ? 1 : 0),
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
                    let manual = manualPageTexts[page.pageNumber]
                    let isOCRPage = ocrPageNumbers?.contains(page.pageNumber)
                        ?? ocrPerformed
                    try execute(
                        """
                        INSERT INTO pages (
                            document_id, page_number, text, text_source,
                            original_ocr_text, text_kind
                        ) VALUES (?, ?, ?, ?, ?, ?)
                        """,
                        bindings: [
                            .integer(documentID),
                            .integer(Int64(page.pageNumber)),
                            .text(page.text),
                            .text(manual == nil
                                ? isOCRPage ? "ocr" : "extracted"
                                : "manual"),
                            manual?.originalOCRText.map(SQLiteValue.text) ?? .null,
                            .text(manual?.kind.rawValue ?? PageTextKind.automatic.rawValue)
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

            for manual in manualPageTexts.values {
                let status: PageContentStatus = manual.kind == .manuallyCorrected
                    ? .manuallyCorrectedText
                    : .manuallyEnteredText
                try execute(
                    """
                    UPDATE page_content_analysis
                    SET status = ?, user_decision = 'notEmpty', updated_at = ?
                    WHERE absolute_path = ? AND original_hash = ? AND page_number = ?
                    """,
                    bindings: [
                        .text(status.rawValue),
                        .real(now),
                        .text(file.url.path),
                        .text(hash),
                        .integer(Int64(manual.pageNumber))
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
                    JOIN documents d ON d.id = c.document_id
                    WHERE NOT EXISTS (
                        SELECT 1 FROM document_locations l
                        WHERE l.document_id = c.document_id AND l.deleted_at IS NULL
                    )
                      AND d.content_type = 'pdf'
                      AND NOT EXISTS (
                          SELECT 1 FROM emails e WHERE e.document_id = d.id
                      )
                      AND NOT EXISTS (
                          SELECT 1 FROM email_attachments a WHERE a.document_id = d.id
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
                  AND content_type = 'pdf'
                  AND NOT EXISTS (
                      SELECT 1 FROM emails e WHERE e.document_id = documents.id
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM email_attachments a
                      WHERE a.document_id = documents.id
                  )
                """
            )
        }
        publishStatusChange(.locationsChanged)
    }

    public func upsertMailSource(
        url: URL,
        format: MailSourceFormat,
        importMode: MailImportMode,
        bookmarkData: Data?,
        mailbox: String? = nil,
        watchEnabled: Bool = false
    ) throws -> Int64 {
        let canonicalPath = url.standardizedFileURL.path
        let sourceKey = SHA256Hasher().hash(
            data: Data("\(format.rawValue)\u{1F}\(canonicalPath)".utf8)
        )
        let now = Date().timeIntervalSince1970
        try execute(
            """
            INSERT INTO mail_import_sources (
                source_key, display_name, source_format, source_path, bookmark_data,
                import_mode, source_status, mailbox_name, watch_enabled,
                last_access_at, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_key) DO UPDATE SET
                display_name = excluded.display_name,
                source_path = excluded.source_path,
                bookmark_data = COALESCE(excluded.bookmark_data, mail_import_sources.bookmark_data),
                import_mode = excluded.import_mode,
                source_status = excluded.source_status,
                mailbox_name = COALESCE(excluded.mailbox_name, mail_import_sources.mailbox_name),
                watch_enabled = excluded.watch_enabled,
                last_access_at = excluded.last_access_at,
                updated_at = excluded.updated_at
            """,
            bindings: [
                .text(sourceKey),
                .text(url.deletingPathExtension().lastPathComponent),
                .text(format.rawValue),
                .text(canonicalPath),
                bookmarkData.map(SQLiteValue.blob) ?? .null,
                .text(importMode.rawValue),
                .text(importMode == .archived
                    ? MailSourceStatus.archivedCopyAvailable.rawValue
                    : MailSourceStatus.available.rawValue),
                mailbox.map(SQLiteValue.text) ?? .null,
                .integer(watchEnabled ? 1 : 0),
                .real(now),
                .real(now),
                .real(now)
            ]
        )
        let sourceID = try scalarInt64(
            "SELECT id FROM mail_import_sources WHERE source_key = ?",
            bindings: [.text(sourceKey)]
        )
        publishStatusChange(.settingsChanged)
        return sourceID
    }

    public func beginMailSourceSynchronization(sourceID: Int64) throws {
        try transaction {
            try execute(
                """
                UPDATE email_source_links
                SET source_present = 0
                WHERE source_id = ?
                """,
                bindings: [.integer(sourceID)]
            )
            try execute(
                """
                UPDATE mail_import_sources
                SET source_status = ?, error_count = 0, updated_at = ?
                WHERE id = ?
                """,
                bindings: [
                    .text(MailSourceStatus.available.rawValue),
                    .real(Date().timeIntervalSince1970),
                    .integer(sourceID)
                ]
            )
        }
    }

    public func importMail(
        _ mail: ParsedMail,
        sourceID: Int64,
        sourceEntryKey: String,
        chunks: [TextChunk],
        embeddings: [[Float]],
        indexedAttachments: [IndexedMailAttachment],
        embeddingModelID: String,
        embeddingModelVersion: String
    ) throws -> MailDatabaseImportResult {
        guard chunks.count == embeddings.count else {
            throw FindoraError.database("Mail-Chunks und Embeddings stimmen nicht überein.")
        }
        for attachment in indexedAttachments
        where attachment.chunks.count != attachment.embeddings.count {
            throw FindoraError.database(
                "Anhang-Chunks und Embeddings stimmen nicht überein."
            )
        }

        let existingRows = try query(
            "SELECT id, raw_sha256 FROM emails WHERE stable_identity = ?",
            bindings: [.text(mail.stableIdentity)]
        )
        let existed = !existingRows.isEmpty
        let unchanged = existingRows.first?.string("raw_sha256") == mail.rawSHA256
        let now = Date().timeIntervalSince1970
        let documentHash = SHA256Hasher().hash(
            data: Data("email:\(mail.stableIdentity)".utf8)
        )

        try transaction {
            try execute(
                """
                INSERT INTO documents (
                    content_hash, page_count, text_layer_present, ocr_status,
                    last_successful_processing, last_indexed_at, active_version,
                    content_type
                ) VALUES (?, 1, 1, 'not_required', ?, ?, 1, 'email')
                ON CONFLICT(content_hash) DO UPDATE SET
                    page_count = 1,
                    text_layer_present = 1,
                    last_successful_processing = excluded.last_successful_processing,
                    last_indexed_at = excluded.last_indexed_at,
                    active_version = 1,
                    content_type = 'email'
                """,
                bindings: [.text(documentHash), .real(now), .real(now)]
            )
            let documentID = try scalarInt64(
                "SELECT id FROM documents WHERE content_hash = ?",
                bindings: [.text(documentHash)]
            )
            let referencesData = try JSONEncoder().encode(mail.references)
            let references = String(data: referencesData, encoding: .utf8) ?? "[]"
            try execute(
                """
                INSERT INTO emails (
                    document_id, stable_identity, message_id, conversation_id, subject,
                    sender_name, sender_address, sent_at, received_at, priority,
                    in_reply_to, message_references, original_text, normalized_text,
                    html_text, character_set, raw_sha256, source_status,
                    attachment_count, processing_status, index_status, imported_at,
                    last_synchronized_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(stable_identity) DO UPDATE SET
                    document_id = excluded.document_id,
                    message_id = excluded.message_id,
                    conversation_id = excluded.conversation_id,
                    subject = excluded.subject,
                    sender_name = excluded.sender_name,
                    sender_address = excluded.sender_address,
                    sent_at = excluded.sent_at,
                    received_at = excluded.received_at,
                    priority = excluded.priority,
                    in_reply_to = excluded.in_reply_to,
                    message_references = excluded.message_references,
                    original_text = excluded.original_text,
                    normalized_text = excluded.normalized_text,
                    html_text = excluded.html_text,
                    character_set = excluded.character_set,
                    raw_sha256 = excluded.raw_sha256,
                    source_status = excluded.source_status,
                    attachment_count = excluded.attachment_count,
                    processing_status = excluded.processing_status,
                    index_status = excluded.index_status,
                    last_synchronized_at = excluded.last_synchronized_at
                """,
                bindings: [
                    .integer(documentID),
                    .text(mail.stableIdentity),
                    mail.messageID.map(SQLiteValue.text) ?? .null,
                    mail.conversationID.map(SQLiteValue.text) ?? .null,
                    .text(mail.subject),
                    mail.sender?.name.map(SQLiteValue.text) ?? .null,
                    mail.sender.map { .text($0.address) } ?? .null,
                    mail.sentAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                    mail.receivedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                    .text(mail.priority.rawValue),
                    mail.inReplyTo.map(SQLiteValue.text) ?? .null,
                    .text(references),
                    .text(mail.originalText),
                    .text(mail.normalizedText),
                    mail.html.map(SQLiteValue.text) ?? .null,
                    mail.characterSet.map(SQLiteValue.text) ?? .null,
                    .text(mail.rawSHA256),
                    .text(MailSourceStatus.available.rawValue),
                    .integer(Int64(mail.attachments.count)),
                    .text(MailImportState.indexed.rawValue),
                    .text(MailImportState.indexed.rawValue),
                    .real(now),
                    .real(now)
                ]
            )
            let emailID = try scalarInt64(
                "SELECT id FROM emails WHERE stable_identity = ?",
                bindings: [.text(mail.stableIdentity)]
            )

            try execute(
                "DELETE FROM email_recipients WHERE email_id = ?",
                bindings: [.integer(emailID)]
            )
            if let sender = mail.sender {
                try insertMailAddress(sender, role: .from, emailID: emailID)
            }
            for role in [MailRecipientRole.to, .cc, .bcc] {
                for address in mail.recipients[role] ?? [] {
                    try insertMailAddress(address, role: role, emailID: emailID)
                }
            }

            try execute(
                """
                INSERT INTO email_source_links (
                    email_id, source_id, source_entry_key, source_present,
                    first_seen_at, last_seen_at, removed_at
                ) VALUES (?, ?, ?, 1, ?, ?, NULL)
                ON CONFLICT(source_id, source_entry_key) DO UPDATE SET
                    email_id = excluded.email_id,
                    source_present = 1,
                    last_seen_at = excluded.last_seen_at,
                    removed_at = NULL
                """,
                bindings: [
                    .integer(emailID),
                    .integer(sourceID),
                    .text(sourceEntryKey),
                    .real(now),
                    .real(now)
                ]
            )

            if !unchanged {
                try deleteSearchRows(documentID: documentID)
                try execute(
                    """
                    INSERT INTO pages (
                        document_id, page_number, text, text_source,
                        original_ocr_text, text_kind
                    ) VALUES (?, 1, ?, 'email', NULL, 'automatic')
                    """,
                    bindings: [.integer(documentID), .text(mail.normalizedText)]
                )
                try insertSearchRows(
                    documentID: documentID,
                    documentHash: documentHash,
                    chunks: chunks,
                    embeddings: embeddings,
                    modifiedAt: mail.sentAt ?? .now,
                    embeddingModelID: embeddingModelID,
                    embeddingModelVersion: embeddingModelVersion,
                    indexedAt: now
                )
            }

            try execute(
                "DELETE FROM email_attachment_links WHERE email_id = ?",
                bindings: [.integer(emailID)]
            )
            for (ordinal, indexed) in indexedAttachments.enumerated() {
                let attachment = indexed.attachment
                try execute(
                    """
                    INSERT INTO documents (
                        content_hash, page_count, text_layer_present, ocr_status,
                        last_successful_processing, last_indexed_at, active_version,
                        content_type
                    ) VALUES (?, ?, ?, 'not_required', ?, ?, 1, 'emailAttachment')
                    ON CONFLICT(content_hash) DO NOTHING
                    """,
                    bindings: [
                        .text(attachment.sha256),
                        .integer(Int64(indexed.pages.count)),
                        .integer(indexed.extractedText.isEmpty ? 0 : 1),
                        .real(now),
                        .real(now)
                    ]
                )
                let attachmentDocumentID = try scalarInt64(
                    "SELECT id FROM documents WHERE content_hash = ?",
                    bindings: [.text(attachment.sha256)]
                )
                try execute(
                    """
                    INSERT INTO email_attachments (
                        document_id, sha256, canonical_file_name, mime_type,
                        byte_count, is_inline, archived_path, extracted_text,
                        processing_status, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(sha256) DO UPDATE SET
                        canonical_file_name = excluded.canonical_file_name,
                        mime_type = excluded.mime_type,
                        byte_count = excluded.byte_count,
                        is_inline = excluded.is_inline,
                        archived_path = COALESCE(excluded.archived_path, email_attachments.archived_path),
                        extracted_text = CASE
                            WHEN excluded.extracted_text != '' THEN excluded.extracted_text
                            ELSE email_attachments.extracted_text
                        END,
                        processing_status = excluded.processing_status,
                        updated_at = excluded.updated_at
                    """,
                    bindings: [
                        .integer(attachmentDocumentID),
                        .text(attachment.sha256),
                        .text(attachment.fileName),
                        .text(attachment.mimeType),
                        .integer(Int64(attachment.data.count)),
                        .integer(attachment.isInline ? 1 : 0),
                        indexed.archivedPath.map(SQLiteValue.text) ?? .null,
                        .text(indexed.extractedText),
                        .text(indexed.extractedText.isEmpty ? "metadataOnly" : "indexed"),
                        .real(now),
                        .real(now)
                    ]
                )
                let attachmentID = try scalarInt64(
                    "SELECT id FROM email_attachments WHERE sha256 = ?",
                    bindings: [.text(attachment.sha256)]
                )
                try execute(
                    """
                    INSERT INTO email_attachment_links (
                        email_id, attachment_id, ordinal, file_name, content_id
                    ) VALUES (?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .integer(emailID),
                        .integer(attachmentID),
                        .integer(Int64(ordinal)),
                        .text(attachment.fileName),
                        attachment.contentID.map(SQLiteValue.text) ?? .null
                    ]
                )

                let existingChunks = try scalarInt64(
                    "SELECT COUNT(*) FROM chunks WHERE document_id = ?",
                    bindings: [.integer(attachmentDocumentID)]
                )
                if existingChunks == 0, !indexed.chunks.isEmpty {
                    for page in indexed.pages {
                        try execute(
                            """
                            INSERT OR REPLACE INTO pages (
                                document_id, page_number, text, text_source,
                                original_ocr_text, text_kind
                            ) VALUES (?, ?, ?, 'attachment', NULL, 'automatic')
                            """,
                            bindings: [
                                .integer(attachmentDocumentID),
                                .integer(Int64(page.pageNumber)),
                                .text(page.text)
                            ]
                        )
                    }
                    try insertSearchRows(
                        documentID: attachmentDocumentID,
                        documentHash: attachment.sha256,
                        chunks: indexed.chunks,
                        embeddings: indexed.embeddings,
                        modifiedAt: mail.sentAt ?? .now,
                        embeddingModelID: embeddingModelID,
                        embeddingModelVersion: embeddingModelVersion,
                        indexedAt: now
                    )
                }
            }
        }
        publishStatusChange(.documentIndexed)
        if unchanged { return .duplicate }
        return existed ? .updated : .imported
    }

    public func finishMailSourceSynchronization(sourceID: Int64) throws {
        let now = Date().timeIntervalSince1970
        try transaction {
            try execute(
                """
                UPDATE email_source_links
                SET removed_at = ?
                WHERE source_id = ? AND source_present = 0 AND removed_at IS NULL
                """,
                bindings: [.real(now), .integer(sourceID)]
            )
            try execute(
                """
                UPDATE emails
                SET source_status = CASE
                    WHEN EXISTS (
                        SELECT 1 FROM email_source_links l
                        WHERE l.email_id = emails.id AND l.source_present = 1
                    ) THEN 'available'
                    WHEN EXISTS (
                        SELECT 1
                        FROM email_source_links l
                        JOIN mail_import_sources s ON s.id = l.source_id
                        WHERE l.email_id = emails.id AND s.import_mode = 'archived'
                    ) THEN 'archivedCopyAvailable'
                    ELSE 'removedFromSource'
                END,
                last_synchronized_at = ?
                """,
                bindings: [.real(now)]
            )
            try execute(
                """
                UPDATE mail_import_sources
                SET last_imported_at = ?,
                    last_synchronized_at = ?,
                    source_status = CASE
                        WHEN import_mode = 'archived' THEN 'archivedCopyAvailable'
                        ELSE 'available'
                    END,
                    message_count = (
                        SELECT COUNT(*) FROM email_source_links WHERE source_id = ?
                    ),
                    attachment_count = (
                        SELECT COUNT(*)
                        FROM email_attachment_links a
                        JOIN email_source_links l ON l.email_id = a.email_id
                        WHERE l.source_id = ?
                    ),
                    storage_bytes = (
                        SELECT COALESCE(SUM(LENGTH(e.normalized_text)), 0)
                        FROM emails e
                        JOIN email_source_links l ON l.email_id = e.id
                        WHERE l.source_id = ?
                    ),
                    updated_at = ?
                WHERE id = ?
                """,
                bindings: [
                    .real(now),
                    .real(now),
                    .integer(sourceID),
                    .integer(sourceID),
                    .integer(sourceID),
                    .real(now),
                    .integer(sourceID)
                ]
            )
        }
        publishStatusChange(.documentIndexed)
    }

    public func mailSources() throws -> [MailImportSource] {
        try query(
            """
            SELECT id, display_name, source_format, source_path, archived_path, import_mode,
                   source_status, mailbox_name, watch_enabled, last_imported_at,
                   last_synchronized_at, message_count, attachment_count,
                   error_count, storage_bytes
            FROM mail_import_sources
            ORDER BY display_name, id
            """
        ).compactMap { row in
            guard let id = row.int64("id"),
                  let displayName = row.string("display_name"),
                  let formatRaw = row.string("source_format"),
                  let format = MailSourceFormat(rawValue: formatRaw),
                  let path = row.string("source_path"),
                  let modeRaw = row.string("import_mode"),
                  let mode = MailImportMode(rawValue: modeRaw),
                  let statusRaw = row.string("source_status"),
                  let status = MailSourceStatus(rawValue: statusRaw) else {
                return nil
            }
            return MailImportSource(
                id: id,
                displayName: displayName,
                format: format,
                path: path,
                archivedPath: row.string("archived_path"),
                importMode: mode,
                status: status,
                mailbox: row.string("mailbox_name"),
                watchEnabled: row.int64("watch_enabled") == 1,
                lastImportedAt: row.double("last_imported_at").map(Date.init(timeIntervalSince1970:)),
                lastSynchronizedAt: row.double("last_synchronized_at").map(Date.init(timeIntervalSince1970:)),
                messageCount: Int(row.int64("message_count") ?? 0),
                attachmentCount: Int(row.int64("attachment_count") ?? 0),
                errorCount: Int(row.int64("error_count") ?? 0),
                storageBytes: row.int64("storage_bytes") ?? 0
            )
        }
    }

    public func mailSource(id: Int64) throws -> MailImportSource? {
        try mailSources().first(where: { $0.id == id })
    }

    public func mailSourceBookmarkData(sourceID: Int64) throws -> Data? {
        try query(
            "SELECT bookmark_data FROM mail_import_sources WHERE id = ?",
            bindings: [.integer(sourceID)]
        ).first?.data("bookmark_data")
    }

    public func setMailSourceWatchEnabled(
        sourceID: Int64,
        enabled: Bool
    ) throws {
        try execute(
            """
            UPDATE mail_import_sources
            SET watch_enabled = ?, updated_at = ?
            WHERE id = ?
            """,
            bindings: [
                .integer(enabled ? 1 : 0),
                .real(Date().timeIntervalSince1970),
                .integer(sourceID)
            ]
        )
        publishStatusChange(.settingsChanged)
    }

    public func setMailSourceArchivedPath(
        sourceID: Int64,
        archivedPath: String
    ) throws {
        try execute(
            """
            UPDATE mail_import_sources
            SET archived_path = ?, source_status = ?, updated_at = ?
            WHERE id = ?
            """,
            bindings: [
                .text(archivedPath),
                .text(MailSourceStatus.archivedCopyAvailable.rawValue),
                .real(Date().timeIntervalSince1970),
                .integer(sourceID)
            ]
        )
        publishStatusChange(.settingsChanged)
    }

    public func reassignMailSource(
        sourceID: Int64,
        url: URL,
        bookmarkData: Data?
    ) throws {
        guard let source = try mailSource(id: sourceID) else {
            throw FindoraError.database("Die E-Mail-Quelle wurde nicht gefunden.")
        }
        let canonicalPath = url.standardizedFileURL.path
        let sourceKey = SHA256Hasher().hash(
            data: Data("\(source.format.rawValue)\u{1F}\(canonicalPath)".utf8)
        )
        try execute(
            """
            UPDATE mail_import_sources
            SET source_key = ?, display_name = ?, source_path = ?,
                bookmark_data = ?, source_status = ?, updated_at = ?
            WHERE id = ?
            """,
            bindings: [
                .text(sourceKey),
                .text(url.deletingPathExtension().lastPathComponent),
                .text(canonicalPath),
                bookmarkData.map(SQLiteValue.blob) ?? .null,
                .text(MailSourceStatus.available.rawValue),
                .real(Date().timeIntervalSince1970),
                .integer(sourceID)
            ]
        )
        publishStatusChange(.settingsChanged)
    }

    public func removeMailSource(sourceID: Int64) throws {
        try transaction {
            try execute(
                "DELETE FROM mail_import_sources WHERE id = ?",
                bindings: [.integer(sourceID)]
            )
            try execute(
                """
                UPDATE emails
                SET source_status = CASE
                    WHEN EXISTS (
                        SELECT 1 FROM email_source_links l
                        WHERE l.email_id = emails.id AND l.source_present = 1
                    ) THEN 'available'
                    ELSE 'indexOnly'
                END
                """
            )
        }
        publishStatusChange(.settingsChanged)
    }

    public func markMailSourceUnavailable(sourceID: Int64) throws {
        try execute(
            """
            UPDATE mail_import_sources
            SET source_status = ?, updated_at = ?
            WHERE id = ?
            """,
            bindings: [
                .text(MailSourceStatus.unavailable.rawValue),
                .real(Date().timeIntervalSince1970),
                .integer(sourceID)
            ]
        )
        publishStatusChange(.settingsChanged)
    }

    public func recordMailImportError(sourceID: Int64, category: String) throws {
        try transaction {
            try execute(
                """
                UPDATE mail_import_sources
                SET error_count = error_count + 1, updated_at = ?
                WHERE id = ?
                """,
                bindings: [
                    .real(Date().timeIntervalSince1970),
                    .integer(sourceID)
                ]
            )
            try execute(
                """
                INSERT INTO errors (category, message, path, created_at)
                VALUES ('E-Mail-Import', ?, NULL, ?)
                """,
                bindings: [
                    .text(category),
                    .real(Date().timeIntervalSince1970)
                ]
            )
        }
        publishStatusChange(.errorRecorded)
    }

    public func databaseQuickCheck() throws -> String {
        let rows = try query("PRAGMA quick_check")
        return rows.first?.values.values.compactMap {
            if case .text(let value) = $0 { return value }
            return nil
        }.first ?? "unbekannt"
    }

    public func logicalStorageUsage() throws -> (
        textBytes: Int64,
        embeddingBytes: Int64
    ) {
        let textBytes = try scalarInt64(
            """
            SELECT
                COALESCE((SELECT SUM(LENGTH(text)) FROM pages), 0)
              + COALESCE((SELECT SUM(LENGTH(original_text) + LENGTH(normalized_text))
                          FROM emails), 0)
              + COALESCE((SELECT SUM(LENGTH(extracted_text))
                          FROM email_attachments), 0)
            """
        )
        let embeddingBytes = try scalarInt64(
            "SELECT COALESCE(SUM(LENGTH(vector)), 0) FROM chunk_embeddings"
        )
        return (textBytes, embeddingBytes)
    }

    public func checkpointAndClose() throws {
        guard let connection else { return }
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
        let result = sqlite3_close_v2(connection)
        guard result == SQLITE_OK else {
            throw databaseError("sqlite3_close_v2")
        }
        self.connection = nil
    }

    private func insertMailAddress(
        _ address: MailAddress,
        role: MailRecipientRole,
        emailID: Int64
    ) throws {
        try execute(
            """
            INSERT INTO email_recipients (email_id, role, display_name, address)
            VALUES (?, ?, ?, ?)
            """,
            bindings: [
                .integer(emailID),
                .text(role.rawValue),
                address.name.map(SQLiteValue.text) ?? .null,
                .text(address.address)
            ]
        )
    }

    private func deleteSearchRows(documentID: Int64) throws {
        try execute(
            """
            DELETE FROM chunks_fts
            WHERE chunk_id IN (SELECT id FROM chunks WHERE document_id = ?)
            """,
            bindings: [.integer(documentID)]
        )
        try execute(
            "DELETE FROM chunks WHERE document_id = ?",
            bindings: [.integer(documentID)]
        )
        try execute(
            "DELETE FROM pages WHERE document_id = ?",
            bindings: [.integer(documentID)]
        )
    }

    private func insertSearchRows(
        documentID: Int64,
        documentHash: String,
        chunks: [TextChunk],
        embeddings: [[Float]],
        modifiedAt: Date,
        embeddingModelID: String,
        embeddingModelVersion: String,
        indexedAt: Double
    ) throws {
        for (index, chunk) in chunks.enumerated() {
            try execute(
                """
                INSERT INTO chunks (
                    id, document_id, document_hash, page_number, ordinal,
                    chunk_text, modified_at, indexed_at, embedding_model_id,
                    embedding_model_version
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(chunk.id),
                    .integer(documentID),
                    .text(documentHash),
                    .integer(Int64(chunk.pageNumber)),
                    .integer(Int64(chunk.ordinal)),
                    .text(chunk.text),
                    .real(modifiedAt.timeIntervalSince1970),
                    .real(indexedAt),
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
                INSERT INTO chunk_embeddings (
                    chunk_id, model_id, model_version, dimensions, vector
                ) VALUES (?, ?, ?, ?, ?)
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
    }

    public func lexicalSearch(
        query searchText: String,
        contentFilter: SearchContentFilter = .all,
        limit: Int = 40
    ) throws -> [SearchSource] {
        let matchQuery = Self.safeFTSQuery(searchText)
        guard !matchQuery.isEmpty else { return [] }
        let filterSQL = Self.contentFilterSQL(contentFilter, alias: "m")
        let rows = try query(
            """
            SELECT c.document_id, c.id AS chunk_id, c.page_number, c.chunk_text,
                   m.file_name, m.absolute_path, m.relative_path, m.content_type,
                   m.mail_subject, m.mail_sender, m.mail_date, m.mailbox,
                   m.parent_email_subject, m.parent_email_sender,
                   m.parent_email_date, bm25(chunks_fts) AS rank
            FROM chunks_fts
            JOIN chunks c ON c.id = chunks_fts.chunk_id
            JOIN search_source_metadata m ON m.document_id = c.document_id
            WHERE chunks_fts MATCH ? AND \(filterSQL)
            ORDER BY rank
            LIMIT ?
            """,
            bindings: [.text(matchQuery), .integer(Int64(limit))]
        )

        return rows.enumerated().compactMap { index, row in
            Self.source(row: row, score: 1.0 / Double(index + 1))
        }
    }

    public func fileNameSearch(
        terms: [String],
        contentFilter: SearchContentFilter = .all,
        limit: Int = 40
    ) throws -> [SearchSource] {
        let normalized = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(12)
        guard !normalized.isEmpty else { return [] }
        let conditions = Array(
            repeating: "lower(m.file_name) LIKE lower(?) ESCAPE '\\'",
            count: normalized.count
        ).joined(separator: " OR ")
        let filterSQL = Self.contentFilterSQL(contentFilter, alias: "m")
        let bindings = normalized.map { term -> SQLiteValue in
            let escaped = term
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            return .text("%\(escaped)%")
        } + [.integer(Int64(limit))]
        let rows = try query(
            """
            SELECT c.document_id, c.id AS chunk_id, c.page_number, c.chunk_text,
                   m.file_name, m.absolute_path, m.relative_path, m.content_type,
                   m.mail_subject, m.mail_sender, m.mail_date, m.mailbox,
                   m.parent_email_subject, m.parent_email_sender,
                   m.parent_email_date
            FROM search_source_metadata m
            JOIN chunks c ON c.id = (
                SELECT first_chunk.id
                FROM chunks first_chunk
                WHERE first_chunk.document_id = m.document_id
                ORDER BY first_chunk.page_number, first_chunk.ordinal
                LIMIT 1
            )
            WHERE \(filterSQL) AND (\(conditions))
            ORDER BY m.file_name
            LIMIT ?
            """,
            bindings: bindings
        )
        return rows.enumerated().compactMap { index, row in
            Self.source(row: row, score: 1.0 / Double(index + 1))
        }
    }

    public func vectorRows(
        modelID: String,
        modelVersion: String,
        contentFilter: SearchContentFilter = .all
    ) throws -> [(SearchSource, [Float])] {
        let filterSQL = Self.contentFilterSQL(contentFilter, alias: "m")
        let rows = try query(
            """
            SELECT c.document_id, c.id AS chunk_id, c.page_number, c.chunk_text,
                   m.file_name, m.absolute_path, m.relative_path, m.content_type,
                   m.mail_subject, m.mail_sender, m.mail_date, m.mailbox,
                   m.parent_email_subject, m.parent_email_sender,
                   m.parent_email_date, e.vector
            FROM chunk_embeddings e
            JOIN chunks c ON c.id = e.chunk_id
            JOIN search_source_metadata m ON m.document_id = c.document_id
            WHERE e.model_id = ? AND e.model_version = ? AND \(filterSQL)
            """,
            bindings: [.text(modelID), .text(modelVersion)]
        )
        return rows.compactMap { row in
            guard let source = Self.source(row: row, score: 0),
                  let data = row.data("vector") else { return nil }
            return (source, Self.decode(vector: data))
        }
    }

    public func searchEvidence(
        documentIDs: Set<Int64>
    ) throws -> [Int64: DocumentSearchEvidence] {
        guard !documentIDs.isEmpty else { return [:] }
        let identifiers = documentIDs.sorted().map(String.init).joined(separator: ",")
        let rows = try query(
            """
            SELECT c.document_id, c.id AS chunk_id, c.page_number, c.chunk_text,
                   COALESCE(p.text_source, 'extracted') AS text_source,
                   q.status AS ocr_quality
            FROM chunks c
            LEFT JOIN pages p
              ON p.document_id = c.document_id AND p.page_number = c.page_number
            LEFT JOIN ocr_page_quality q
              ON q.document_id = c.document_id AND q.page_number = c.page_number
            WHERE c.document_id IN (\(identifiers))
            ORDER BY c.document_id, c.page_number, c.ordinal
            """
        )
        var grouped: [Int64: [SearchEvidenceChunk]] = [:]
        for row in rows {
            guard let documentID = row.int64("document_id"),
                  let chunkID = row.string("chunk_id"),
                  let pageNumber = row.int64("page_number"),
                  let text = row.string("chunk_text"),
                  let textSource = row.string("text_source") else { continue }
            grouped[documentID, default: []].append(
                SearchEvidenceChunk(
                    chunkID: chunkID,
                    pageNumber: Int(pageNumber),
                    text: text,
                    textSource: textSource,
                    ocrQuality: row.string("ocr_quality")
                )
            )
        }
        var evidence: [Int64: DocumentSearchEvidence] = [:]
        for (documentID, chunks) in grouped {
            evidence[documentID] = DocumentSearchEvidence(
                documentID: documentID,
                chunks: chunks
            )
        }
        return evidence
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
            WITH current_jobs AS (
                SELECT * FROM processing_jobs WHERE state != 'retired'
            ),
            active_locations AS (
                SELECT * FROM document_locations WHERE deleted_at IS NULL
            ),
            active_documents AS (
                SELECT DISTINCT document_id FROM active_locations
            ),
            active_chunks AS (
                SELECT c.*
                FROM chunks c
                JOIN active_documents d ON d.document_id = c.document_id
            ),
            active_embeddings AS (
                SELECT e.*
                FROM chunk_embeddings e
                JOIN active_chunks c ON c.id = e.chunk_id
            ),
            indexed_job_documents AS (
                SELECT
                    j.job_key,
                    d.id AS document_id,
                    d.text_layer_present,
                    EXISTS (
                        SELECT 1 FROM pages p
                        WHERE p.document_id = d.id
                          AND p.text_source = 'ocr'
                          AND length(trim(p.text)) > 0
                    ) AS has_ocr_text,
                    EXISTS (
                        SELECT 1 FROM pages p
                        WHERE p.document_id = d.id
                          AND length(trim(p.text)) > 0
                    ) AS has_any_text
                FROM current_jobs j
                JOIN documents d ON d.content_hash = j.content_hash
                WHERE j.state = 'indexed'
            ),
            current_page_analysis AS (
                SELECT a.*
                FROM page_content_analysis a
                JOIN processing_jobs j ON j.job_key = a.absolute_path
                WHERE j.state NOT IN ('retired', 'unavailable')
                  AND j.content_hash = a.original_hash
            )
            SELECT
                (SELECT COUNT(*) FROM current_jobs) AS total_pdfs,
                (SELECT COUNT(*) FROM current_jobs WHERE state = 'indexed')
                    AS indexed_pdfs,
                (SELECT COUNT(*) FROM indexed_job_documents
                 WHERE has_ocr_text = 0 AND text_layer_present = 1)
                    AS fully_searchable_pdfs,
                (SELECT COUNT(*) FROM indexed_job_documents
                 WHERE has_ocr_text = 1)
                    AS ocr_supplemented_pdfs,
                (SELECT COUNT(*) FROM indexed_job_documents
                 WHERE has_ocr_text = 0 AND has_any_text = 0)
                    AS indexed_without_text_pdfs,
                (SELECT COUNT(*) FROM indexed_job_documents
                 WHERE has_ocr_text = 0 AND has_any_text = 1
                   AND text_layer_present = 0)
                    AS other_indexed_pdfs,
                (SELECT COUNT(*) FROM current_jobs
                 WHERE state IN ('ocrQueued', 'ocrRunning'))
                    AS ocr_required_pdfs,
                (SELECT COUNT(*) FROM current_jobs
                 WHERE state = 'failed' AND last_stage = 'ocrRunning')
                    AS ocr_failed_pdfs,
                (SELECT COUNT(*) FROM current_jobs
                 WHERE state IN ('discovered', 'waitingForStability', 'ocrQueued'))
                    AS pending_jobs,
                (SELECT COUNT(*) FROM current_jobs
                 WHERE state IN ('extracting', 'ocrRunning', 'indexing'))
                    AS processing_jobs,
                (SELECT COUNT(*) FROM processing_jobs WHERE state = 'retired')
                    AS skipped_jobs,
                (SELECT COUNT(*) FROM current_jobs WHERE state = 'failed')
                    AS failed_jobs,
                (SELECT COUNT(*) FROM current_jobs WHERE state = 'unavailable')
                    AS unavailable_jobs,
                (SELECT COUNT(*) FROM indexed_job_documents j
                 JOIN pages p ON p.document_id = j.document_id
                 WHERE p.text_source = 'extracted' AND length(trim(p.text)) > 0)
                    AS pages_with_pdf_text,
                (SELECT COUNT(*) FROM indexed_job_documents j
                 JOIN pages p ON p.document_id = j.document_id
                 WHERE p.text_source = 'ocr' AND length(trim(p.text)) > 0)
                    AS pages_with_ocr_text,
                (SELECT COUNT(*) FROM indexed_job_documents j
                 JOIN pages p ON p.document_id = j.document_id
                 WHERE p.text_source = 'manual' AND length(trim(p.text)) > 0)
                    AS pages_with_manual_text,
                (SELECT COUNT(*) FROM indexed_job_documents j
                 JOIN pages p ON p.document_id = j.document_id
                 WHERE length(trim(p.text)) = 0)
                    AS pages_without_usable_text,
                (SELECT COUNT(*) FROM active_chunks) AS total_chunks,
                (SELECT COUNT(*) FROM active_embeddings)
                    AS embedded_chunks,
                (SELECT COUNT(*) FROM active_embeddings
                 WHERE model_id = 'builtin-token-hash')
                    AS fallback_embedded_chunks,
                (SELECT COUNT(*) FROM active_embeddings
                 WHERE lower(model_id) LIKE '%e5%')
                    AS e5_embedded_chunks,
                (SELECT COUNT(*) FROM active_embeddings
                 WHERE model_id != 'builtin-token-hash'
                   AND lower(model_id) NOT LIKE '%e5%')
                    AS other_embedded_chunks,
                MAX(
                    0,
                    (SELECT COALESCE(SUM(location_count - 1), 0)
                     FROM (
                         SELECT COUNT(*) AS location_count
                         FROM processing_jobs
                         WHERE state NOT IN ('retired', 'unavailable')
                           AND content_hash IS NOT NULL
                         GROUP BY content_hash
                         HAVING COUNT(*) > 1
                     ))
                ) AS duplicate_locations,
                (SELECT COUNT(*) FROM processing_jobs
                 WHERE state IN ('retired', 'unavailable'))
                    AS missing_or_moved_files,
                (SELECT COUNT(*) FROM ocr_page_quality q
                 JOIN indexed_job_documents d ON d.document_id = q.document_id
                 WHERE q.status = 'good') AS ocr_quality_good,
                (SELECT COUNT(*) FROM ocr_page_quality q
                 JOIN indexed_job_documents d ON d.document_id = q.document_id
                 WHERE q.status = 'review') AS ocr_quality_review,
                (SELECT COUNT(*) FROM ocr_page_quality q
                 JOIN indexed_job_documents d ON d.document_id = q.document_id
                 WHERE q.status = 'likelyFailed') AS ocr_quality_failed,
                (SELECT COUNT(*)
                 FROM page_content_analysis a
                 JOIN processing_jobs j ON j.job_key = a.absolute_path
                 WHERE j.state NOT IN ('retired', 'unavailable')
                   AND j.content_hash = a.original_hash
                   AND a.status IN ('unreviewed', 'safelyEmpty', 'probablyEmpty')
                   AND a.user_decision NOT IN ('notEmpty', 'excluded'))
                    AS empty_page_candidates,
                (SELECT COUNT(*)
                 FROM (
                     SELECT a.absolute_path
                     FROM page_content_analysis a
                     JOIN processing_jobs j ON j.job_key = a.absolute_path
                     WHERE j.state NOT IN ('retired', 'unavailable')
                       AND j.content_hash = a.original_hash
                     GROUP BY a.absolute_path
                     HAVING COUNT(*) = MAX(a.page_count)
                        AND SUM(
                            CASE WHEN a.status IN ('safelyEmpty', 'probablyEmpty')
                                      AND a.user_decision NOT IN ('notEmpty', 'excluded')
                                 THEN 1 ELSE 0 END
                        ) = MAX(a.page_count)
                 )) AS fully_empty_pdfs,
                (SELECT COUNT(*) FROM current_page_analysis
                 WHERE status = 'safelyEmpty'
                   AND user_decision NOT IN ('notEmpty', 'excluded'))
                    AS safely_empty_pages,
                (SELECT COUNT(*) FROM current_page_analysis
                 WHERE status = 'probablyEmpty'
                   AND user_decision NOT IN ('notEmpty', 'excluded'))
                    AS probably_empty_pages,
                (SELECT COUNT(*) FROM processing_jobs
                 WHERE state = 'ocrRunning' AND ocr_attempt_current > 0)
                    AS ocr_retrying_pages,
                (SELECT COUNT(*) FROM current_page_analysis
                 WHERE status IN (
                     'needsOCRReview', 'imageWithoutRecognizedText',
                     'ocrNoResult', 'technicalReviewError'
                 ) AND user_decision != 'excluded')
                    AS ocr_review_pages,
                (SELECT COUNT(*) FROM current_page_analysis
                 WHERE user_decision = 'notEmpty')
                    AS manually_not_empty_pages,
                (SELECT COUNT(*) FROM current_page_analysis
                 WHERE status = 'ocrNoResult')
                    AS ocr_no_result_pages,
                (SELECT COUNT(*) FROM current_page_analysis
                 WHERE status = 'manuallyCorrectedText')
                    AS manually_corrected_pages,
                (SELECT COUNT(*) FROM current_page_analysis
                 WHERE status = 'manuallyEnteredText')
                    AS manually_entered_pages,
                (SELECT COUNT(*) FROM processing_jobs
                 WHERE state IN ('indexed', 'failed')) AS processed_jobs,
                (SELECT COUNT(*) FROM processing_jobs
                 WHERE state NOT IN ('retired', 'unavailable')) AS total_jobs
            """
        ).first
        var result = DocumentStatistics()
        result.totalPDFs = Int(row?.int64("total_pdfs") ?? 0)
        result.indexedPDFs = Int(row?.int64("indexed_pdfs") ?? 0)
        result.fullySearchablePDFs = Int(row?.int64("fully_searchable_pdfs") ?? 0)
        result.ocrSupplementedPDFs = Int(row?.int64("ocr_supplemented_pdfs") ?? 0)
        result.indexedWithoutUsableTextPDFs =
            Int(row?.int64("indexed_without_text_pdfs") ?? 0)
        result.otherIndexedPDFs = Int(row?.int64("other_indexed_pdfs") ?? 0)
        result.searchablePDFs = result.fullySearchablePDFs
        result.withoutTextLayerPDFs = max(
            0,
            result.indexedPDFs - result.fullySearchablePDFs
        )
        result.ocrRequiredPDFs = Int(row?.int64("ocr_required_pdfs") ?? 0)
        result.ocrProcessedPDFs = result.ocrSupplementedPDFs
        result.ocrFailedPDFs = Int(row?.int64("ocr_failed_pdfs") ?? 0)
        result.pendingJobs = Int(row?.int64("pending_jobs") ?? 0)
        result.processingJobs = Int(row?.int64("processing_jobs") ?? 0)
        result.skippedJobs = Int(row?.int64("skipped_jobs") ?? 0)
        result.failedJobs = Int(row?.int64("failed_jobs") ?? 0)
        result.unavailableJobs = Int(row?.int64("unavailable_jobs") ?? 0)
        result.pagesWithPDFText = Int(row?.int64("pages_with_pdf_text") ?? 0)
        result.pagesWithOCRText = Int(row?.int64("pages_with_ocr_text") ?? 0)
        result.pagesWithManualText = Int(row?.int64("pages_with_manual_text") ?? 0)
        result.pagesWithoutUsableText =
            Int(row?.int64("pages_without_usable_text") ?? 0)
        result.totalChunks = Int(row?.int64("total_chunks") ?? 0)
        result.embeddedChunks = Int(row?.int64("embedded_chunks") ?? 0)
        result.fallbackEmbeddedChunks = Int(row?.int64("fallback_embedded_chunks") ?? 0)
        result.e5EmbeddedChunks = Int(row?.int64("e5_embedded_chunks") ?? 0)
        result.otherEmbeddedChunks = Int(row?.int64("other_embedded_chunks") ?? 0)
        result.duplicateLocations = Int(row?.int64("duplicate_locations") ?? 0)
        result.missingOrMovedFiles = Int(row?.int64("missing_or_moved_files") ?? 0)
        result.ocrQualityGoodPages = Int(row?.int64("ocr_quality_good") ?? 0)
        result.ocrQualityReviewPages = Int(row?.int64("ocr_quality_review") ?? 0)
        result.ocrQualityFailedPages = Int(row?.int64("ocr_quality_failed") ?? 0)
        result.emptyPageCandidates = Int(row?.int64("empty_page_candidates") ?? 0)
        result.fullyEmptyPDFs = Int(row?.int64("fully_empty_pdfs") ?? 0)
        result.safelyEmptyPages = Int(row?.int64("safely_empty_pages") ?? 0)
        result.probablyEmptyPages = Int(row?.int64("probably_empty_pages") ?? 0)
        result.ocrRetryingPages = Int(row?.int64("ocr_retrying_pages") ?? 0)
        result.ocrReviewPages = Int(row?.int64("ocr_review_pages") ?? 0)
        result.manuallyNotEmptyPages = Int(row?.int64("manually_not_empty_pages") ?? 0)
        result.ocrNoResultPages = Int(row?.int64("ocr_no_result_pages") ?? 0)
        result.manuallyCorrectedPages = Int(row?.int64("manually_corrected_pages") ?? 0)
        result.manuallyEnteredPages = Int(row?.int64("manually_entered_pages") ?? 0)
        result.processedJobs = Int(row?.int64("processed_jobs") ?? 0)
        result.totalJobs = Int(row?.int64("total_jobs") ?? 0)
        result.isPaused = try setting(key: "processingPaused") == "1"
        result.pausedJobs = result.isPaused
            ? result.pendingJobs + result.processingJobs
            : 0

        if let current = try query(
            """
            SELECT state, file_name, ocr_engine, ocr_attempt_current,
                   ocr_attempt_total, ocr_strategy
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
            result.currentOCREngine = current.string("ocr_engine")
                .flatMap(OCREngine.init(rawValue:))?
                .displayName
            if result.isPaused {
                result.currentStep = "Pausiert"
            } else if let attempt = current.int64("ocr_attempt_current"),
                      let total = current.int64("ocr_attempt_total"),
                      attempt > 0,
                      total > 0 {
                let strategy = current.string("ocr_strategy") ?? "OCR-Strategie"
                result.currentStep =
                    "OCR wird verbessert · Versuch \(attempt) von \(total) · \(strategy)"
            } else {
                result.currentStep = current.string("state")
                    .flatMap(ProcessingState.init(rawValue:))?
                    .displayName
            }
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

    public func checkStatusConsistency() throws -> StatusConsistencyReport {
        let snapshot = try statistics()
        var issues: [StatusConsistencyIssue] = []

        if snapshot.totalPDFs != snapshot.exclusiveCurrentJobStates {
            issues.append(
                StatusConsistencyIssue(
                    invariant: "Aktuelle PDF-Zustände",
                    details: "\(snapshot.totalPDFs) PDFs, aber "
                        + "\(snapshot.exclusiveCurrentJobStates) exklusive Zustände."
                )
            )
        }
        if snapshot.indexedPDFs != snapshot.exclusiveIndexedPDFs {
            issues.append(
                StatusConsistencyIssue(
                    invariant: "Indexklassifikation",
                    details: "\(snapshot.indexedPDFs) indexiert, aber "
                        + "\(snapshot.exclusiveIndexedPDFs) klassifiziert."
                )
            )
        }
        if snapshot.embeddedChunks != snapshot.classifiedEmbeddings {
            issues.append(
                StatusConsistencyIssue(
                    invariant: "Embeddingtypen",
                    details: "\(snapshot.embeddedChunks) Embeddings, aber "
                        + "\(snapshot.classifiedEmbeddings) Typzuordnungen."
                )
            )
        }

        let namedValues: [(String, Int)] = [
            ("PDFs insgesamt", snapshot.totalPDFs),
            ("Indexiert", snapshot.indexedPDFs),
            ("Bereits vollständig durchsuchbar", snapshot.fullySearchablePDFs),
            ("Durch OCR ergänzt", snapshot.ocrSupplementedPDFs),
            ("Ohne verwertbaren Text", snapshot.indexedWithoutUsableTextPDFs),
            ("In Warteschlange", snapshot.pendingJobs),
            ("In Bearbeitung", snapshot.processingJobs),
            ("Fehlgeschlagen", snapshot.failedJobs),
            ("Chunks", snapshot.totalChunks),
            ("Embeddings", snapshot.embeddedChunks)
        ]
        for (name, value) in namedValues where value < 0 {
            issues.append(
                StatusConsistencyIssue(
                    invariant: "Nichtnegative Zähler",
                    details: "\(name) ist \(value)."
                )
            )
        }
        return StatusConsistencyReport(statistics: snapshot, issues: issues)
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
            throw FindoraError.database("Chunk- und Embedding-Anzahl stimmen nicht überein.")
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

    public func resetAutomaticOCRAndAnalysis() throws {
        try transaction {
            let now = Date().timeIntervalSince1970
            try execute("DELETE FROM chunks_fts")
            try execute("DELETE FROM chunk_embeddings")
            try execute("DELETE FROM chunks")
            try execute("DELETE FROM ocr_page_quality")
            try execute("DELETE FROM ocr_page_attempts")
            try execute(
                "DELETE FROM page_content_analysis WHERE user_decision = 'undecided'"
            )
            try execute(
                """
                UPDATE documents
                SET ocr_status = 'pending',
                    last_successful_processing = NULL, last_indexed_at = NULL
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
                """,
                bindings: [.real(now)]
            )
        }
        publishStatusChange(.maintenanceCompleted)
    }

    public func resetOCRData() throws {
        try resetAutomaticOCRAndAnalysis()
    }

    public func deleteDocumentIndex() throws {
        try transaction {
            try execute("DELETE FROM chunks_fts")
            try execute("DELETE FROM ocr_page_attempts")
            try execute("DELETE FROM page_content_analysis")
            try execute("DELETE FROM processing_jobs")
            try execute("DELETE FROM document_locations")
            try execute("DELETE FROM documents")
            try execute("DELETE FROM errors")
            try execute("DELETE FROM search_history")
            try execute("DELETE FROM processing_sessions")
        }
        publishStatusChange(.maintenanceCompleted)
    }

    public func repairIndex() throws -> String {
        let integrity = try query("PRAGMA integrity_check").first?.string("integrity_check") ?? "unknown"
        guard integrity == "ok" else {
            throw FindoraError.database("SQLite-Integritätsprüfung: \(integrity)")
        }
        let foreignKeys = try query("PRAGMA foreign_key_check")
        guard foreignKeys.isEmpty else {
            throw FindoraError.database(
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

    public func saveProcessingSession(
        _ session: ProcessingSessionSnapshot
    ) throws {
        try execute(
            """
            INSERT INTO processing_sessions (
                id, phase, started_at, total_count, completed_count,
                failed_count, current_file, is_paused, finished_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                phase = excluded.phase,
                total_count = excluded.total_count,
                completed_count = excluded.completed_count,
                failed_count = excluded.failed_count,
                current_file = excluded.current_file,
                is_paused = excluded.is_paused,
                finished_at = excluded.finished_at,
                updated_at = excluded.updated_at
            """,
            bindings: [
                .text(session.id),
                .text(session.phase.rawValue),
                .real(session.startedAt.timeIntervalSince1970),
                .integer(Int64(session.total)),
                .integer(Int64(session.completed)),
                .integer(Int64(session.failed)),
                session.currentFile.map(SQLiteValue.text) ?? .null,
                .integer(session.isPaused ? 1 : 0),
                session.finishedAt.map {
                    .real($0.timeIntervalSince1970)
                } ?? .null,
                .real(Date().timeIntervalSince1970)
            ]
        )
        publishStatusChange(.jobChanged)
    }

    public func latestProcessingSession() throws -> ProcessingSessionSnapshot? {
        guard let row = try query(
            """
            SELECT * FROM processing_sessions
            ORDER BY updated_at DESC LIMIT 1
            """
        ).first,
        let id = row.string("id"),
        let phaseRaw = row.string("phase"),
        let phase = ProcessingSessionPhase(rawValue: phaseRaw),
        let started = row.double("started_at"),
        let total = row.int64("total_count"),
        let completed = row.int64("completed_count"),
        let failed = row.int64("failed_count"),
        let paused = row.int64("is_paused") else { return nil }
        return ProcessingSessionSnapshot(
            id: id,
            phase: phase,
            startedAt: Date(timeIntervalSince1970: started),
            total: Int(total),
            completed: Int(completed),
            failed: Int(failed),
            currentFile: row.string("current_file"),
            isPaused: paused == 1,
            finishedAt: row.double("finished_at").map {
                Date(timeIntervalSince1970: $0)
            }
        )
    }

    public func registerInstalledModel(
        modelID: String,
        modelVersion: String,
        kind: ModelKind,
        installedPath: String,
        integrityCheckedAt: Date
    ) throws {
        try execute(
            """
            INSERT INTO model_states (
                model_id, model_version, kind, installed_path, enabled,
                integrity_checked_at, updated_at
            ) VALUES (?, ?, ?, ?, 0, ?, ?)
            ON CONFLICT(model_id, model_version) DO UPDATE SET
                kind = excluded.kind,
                installed_path = excluded.installed_path,
                integrity_checked_at = excluded.integrity_checked_at,
                updated_at = excluded.updated_at
            """,
            bindings: [
                .text(modelID),
                .text(modelVersion),
                .text(kind.rawValue),
                .text(installedPath),
                .real(integrityCheckedAt.timeIntervalSince1970),
                .real(Date().timeIntervalSince1970)
            ]
        )
    }

    public func setModelEnabled(
        modelID: String?,
        modelVersion: String?,
        kind: ModelKind
    ) throws {
        try transaction {
            try execute(
                "UPDATE model_states SET enabled = 0, updated_at = ? WHERE kind = ?",
                bindings: [
                    .real(Date().timeIntervalSince1970),
                    .text(kind.rawValue)
                ]
            )
            if let modelID, let modelVersion {
                try execute(
                    """
                    UPDATE model_states
                    SET enabled = 1, updated_at = ?
                    WHERE model_id = ? AND model_version = ? AND kind = ?
                    """,
                    bindings: [
                        .real(Date().timeIntervalSince1970),
                        .text(modelID),
                        .text(modelVersion),
                        .text(kind.rawValue)
                    ]
                )
            }
        }
        publishStatusChange(.settingsChanged)
    }

    public func modelStates() throws -> [StoredModelState] {
        try query(
            """
            SELECT model_id, model_version, kind, installed_path, enabled,
                   integrity_checked_at
            FROM model_states
            ORDER BY kind, model_id, model_version
            """
        ).compactMap { row in
            guard let id = row.string("model_id"),
                  let version = row.string("model_version"),
                  let kindRaw = row.string("kind"),
                  let kind = ModelKind(rawValue: kindRaw),
                  let path = row.string("installed_path"),
                  let enabled = row.int64("enabled") else { return nil }
            return StoredModelState(
                modelID: id,
                modelVersion: version,
                kind: kind,
                installedPath: path,
                enabled: enabled == 1,
                integrityCheckedAt: row.double("integrity_checked_at").map {
                    Date(timeIntervalSince1970: $0)
                }
            )
        }
    }

    public func removeModelState(modelID: String, modelVersion: String) throws {
        try execute(
            "DELETE FROM model_states WHERE model_id = ? AND model_version = ?",
            bindings: [.text(modelID), .text(modelVersion)]
        )
        publishStatusChange(.settingsChanged)
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
        if current < 6 {
            try transaction {
                for statement in Self.migration6 {
                    try execute(statement)
                }
                try execute(
                    "INSERT INTO schema_migrations (version, applied_at) VALUES (6, ?)",
                    bindings: [.real(Date().timeIntervalSince1970)]
                )
            }
        }
        if current < 7 {
            try transaction {
                for statement in Self.migration7 {
                    try execute(statement)
                }
                try execute(
                    "INSERT INTO schema_migrations (version, applied_at) VALUES (7, ?)",
                    bindings: [.real(Date().timeIntervalSince1970)]
                )
            }
        }
        if current < 8 {
            try transaction {
                for statement in Self.migration8 {
                    try execute(statement)
                }
                try execute(
                    "INSERT INTO schema_migrations (version, applied_at) VALUES (8, ?)",
                    bindings: [.real(Date().timeIntervalSince1970)]
                )
            }
        }
        if current < 9 {
            try transaction {
                for statement in Self.migration9 {
                    try execute(statement)
                }
                try execute(
                    "INSERT INTO schema_migrations (version, applied_at) VALUES (9, ?)",
                    bindings: [.real(Date().timeIntervalSince1970)]
                )
            }
        }
        if current < 10 {
            try transaction {
                let hasDocumentSchema = try scalarInt64(
                    """
                    SELECT COUNT(*) FROM sqlite_master
                    WHERE type = 'table' AND name = 'documents'
                    """
                ) > 0
                if hasDocumentSchema {
                    for statement in Self.migration10 {
                        try execute(statement)
                    }
                }
                try execute(
                    "INSERT INTO schema_migrations (version, applied_at) VALUES (10, ?)",
                    bindings: [.real(Date().timeIntervalSince1970)]
                )
            }
        }
    }

    private func ensureOpen() throws {
        guard connection != nil else {
            throw FindoraError.database("Die Datenbank wurde noch nicht initialisiert.")
        }
    }

    private func removeOrphanedDocumentsInTransaction() throws {
        try execute(
            """
            DELETE FROM chunks_fts
            WHERE chunk_id IN (
                SELECT c.id
                FROM chunks c
                JOIN documents d ON d.id = c.document_id
                WHERE NOT EXISTS (
                    SELECT 1 FROM document_locations l
                    WHERE l.document_id = c.document_id AND l.deleted_at IS NULL
                )
                  AND d.content_type = 'pdf'
                  AND NOT EXISTS (
                      SELECT 1 FROM emails e WHERE e.document_id = d.id
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM email_attachments a WHERE a.document_id = d.id
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
              AND content_type = 'pdf'
              AND NOT EXISTS (
                  SELECT 1 FROM emails e WHERE e.document_id = documents.id
              )
              AND NOT EXISTS (
                  SELECT 1 FROM email_attachments a
                  WHERE a.document_id = documents.id
              )
            """
        )
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

    private func databaseError(_ sql: String) -> FindoraError {
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

    private static func contentFilterSQL(
        _ filter: SearchContentFilter,
        alias: String
    ) -> String {
        switch filter {
        case .all:
            return "1 = 1"
        case .documents:
            return "\(alias).content_type = 'pdf'"
        case .emails:
            return "\(alias).content_type = 'email'"
        case .attachments:
            return "\(alias).content_type = 'emailAttachment'"
        }
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
        let contentType = row.string("content_type")
            .flatMap(FindoraContentType.init(rawValue:))
            ?? .pdf
        let sourceID = contentType == .email
            ? "\(chunkID)|email|\(documentID)"
            : "\(chunkID)|\(absolutePath)"
        return SearchSource(
            id: sourceID,
            documentID: documentID,
            chunkID: chunkID,
            fileName: fileName,
            absolutePath: absolutePath,
            relativePath: relativePath,
            pageNumber: Int(page),
            excerpt: excerpt,
            score: score,
            contentType: contentType,
            mailSubject: row.string("mail_subject"),
            mailSender: row.string("mail_sender"),
            mailDate: row.double("mail_date").map(Date.init(timeIntervalSince1970:)),
            mailbox: row.string("mailbox"),
            parentEmailSubject: row.string("parent_email_subject"),
            parentEmailSender: row.string("parent_email_sender"),
            parentEmailDate: row.double("parent_email_date").map(Date.init(timeIntervalSince1970:))
        )
    }

    private static func emptyPageCandidate(_ row: SQLiteRow) -> EmptyPageCandidate? {
        guard let path = row.string("absolute_path"),
              let relative = row.string("relative_path"),
              let name = row.string("file_name"),
              let hash = row.string("original_hash"),
              let pageNumber = row.int64("page_number"),
              let pageCount = row.int64("page_count"),
              let statusRaw = row.string("status"),
              let status = PageContentStatus(rawValue: statusRaw),
              let confidence = row.double("confidence"),
              let reason = row.string("reason"),
              let renderSucceeded = row.int64("render_succeeded"),
              let pixelWidth = row.int64("pixel_width"),
              let pixelHeight = row.int64("pixel_height"),
              let whiteRatio = row.double("white_ratio"),
              let darkPixelRatio = row.double("dark_pixel_ratio"),
              let variance = row.double("variance"),
              let edgeRatio = row.double("edge_ratio"),
              let contrast = row.double("contrast"),
              let characterCount = row.int64("character_count"),
              let wordCount = row.int64("word_count"),
              let embeddedImageCount = row.int64("embedded_image_count"),
              let annotationCount = row.int64("annotation_count"),
              let hasSmallText = row.int64("has_small_text"),
              let decisionRaw = row.string("user_decision"),
              let decision = PageReviewDecision(rawValue: decisionRaw) else {
            return nil
        }
        return EmptyPageCandidate(
            absolutePath: path,
            relativePath: relative,
            fileName: name,
            originalHash: hash,
            pageNumber: Int(pageNumber),
            pageCount: Int(pageCount),
            status: status,
            confidence: confidence,
            reason: reason,
            metrics: PageVisualMetrics(
                renderSucceeded: renderSucceeded == 1,
                pixelWidth: Int(pixelWidth),
                pixelHeight: Int(pixelHeight),
                whiteRatio: whiteRatio,
                darkPixelRatio: darkPixelRatio,
                variance: variance,
                edgeRatio: edgeRatio,
                contrast: contrast,
                characterCount: Int(characterCount),
                wordCount: Int(wordCount),
                ocrConfidence: row.double("ocr_confidence"),
                embeddedImageCount: Int(embeddedImageCount),
                annotationCount: Int(annotationCount),
                hasSmallText: hasSmallText == 1
            ),
            decision: decision
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

    private static let migration6 = [
        "ALTER TABLE processing_jobs ADD COLUMN ocr_engine TEXT"
    ]

    private static let migration7 = [
        """
        CREATE TABLE page_content_analysis (
            absolute_path TEXT NOT NULL,
            original_hash TEXT NOT NULL,
            page_number INTEGER NOT NULL,
            page_count INTEGER NOT NULL,
            status TEXT NOT NULL,
            confidence REAL NOT NULL,
            reason TEXT NOT NULL,
            render_succeeded INTEGER NOT NULL,
            pixel_width INTEGER NOT NULL,
            pixel_height INTEGER NOT NULL,
            white_ratio REAL NOT NULL,
            dark_pixel_ratio REAL NOT NULL,
            variance REAL NOT NULL,
            edge_ratio REAL NOT NULL,
            contrast REAL NOT NULL,
            character_count INTEGER NOT NULL,
            word_count INTEGER NOT NULL,
            ocr_confidence REAL,
            embedded_image_count INTEGER NOT NULL,
            annotation_count INTEGER NOT NULL,
            has_small_text INTEGER NOT NULL,
            user_decision TEXT NOT NULL DEFAULT 'undecided',
            updated_at REAL NOT NULL,
            PRIMARY KEY(absolute_path, page_number)
        )
        """,
        "CREATE INDEX idx_page_analysis_status ON page_content_analysis(status, user_decision)",
        "CREATE INDEX idx_page_analysis_hash ON page_content_analysis(original_hash)"
    ]

    private static let migration8 = [
        "ALTER TABLE page_content_analysis ADD COLUMN decision_at REAL",
        "ALTER TABLE page_content_analysis ADD COLUMN decision_source TEXT",
        "ALTER TABLE pages ADD COLUMN original_ocr_text TEXT",
        "ALTER TABLE pages ADD COLUMN text_kind TEXT NOT NULL DEFAULT 'automatic'",
        "ALTER TABLE processing_jobs ADD COLUMN ocr_attempt_current INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE processing_jobs ADD COLUMN ocr_attempt_total INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE processing_jobs ADD COLUMN ocr_strategy TEXT",
        """
        CREATE TABLE ocr_page_attempts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            absolute_path TEXT NOT NULL,
            original_hash TEXT NOT NULL,
            page_number INTEGER NOT NULL,
            strategy_id TEXT NOT NULL,
            strategy_name TEXT NOT NULL,
            engine TEXT NOT NULL,
            preprocessing TEXT NOT NULL,
            recognized_text TEXT NOT NULL,
            quality_score REAL NOT NULL,
            quality_status TEXT NOT NULL,
            character_count INTEGER NOT NULL,
            word_count INTEGER NOT NULL,
            mean_confidence REAL,
            recognized_language TEXT NOT NULL,
            duration_seconds REAL NOT NULL,
            is_best INTEGER NOT NULL DEFAULT 0,
            completed_at REAL NOT NULL,
            UNIQUE(absolute_path, original_hash, page_number, strategy_id)
        )
        """,
        """
        CREATE INDEX idx_ocr_attempt_review
        ON ocr_page_attempts(absolute_path, original_hash, page_number, is_best)
        """,
        """
        UPDATE page_content_analysis
        SET status = CASE status
            WHEN 'fullyEmpty' THEN 'unreviewed'
            WHEN 'imageWithoutText' THEN 'imageWithoutRecognizedText'
            WHEN 'content' THEN 'contentDetected'
            WHEN 'technicalError' THEN 'technicalReviewError'
            ELSE status
        END
        WHERE user_decision = 'undecided'
        """
    ]

    private static let migration9 = [
        """
        CREATE TABLE model_states (
            model_id TEXT NOT NULL,
            model_version TEXT NOT NULL,
            kind TEXT NOT NULL,
            installed_path TEXT NOT NULL,
            enabled INTEGER NOT NULL DEFAULT 0,
            integrity_checked_at REAL,
            updated_at REAL NOT NULL,
            PRIMARY KEY(model_id, model_version)
        )
        """,
        "CREATE UNIQUE INDEX idx_model_state_enabled_kind ON model_states(kind) WHERE enabled = 1",
        """
        CREATE TABLE processing_sessions (
            id TEXT PRIMARY KEY,
            phase TEXT NOT NULL,
            started_at REAL NOT NULL,
            total_count INTEGER NOT NULL DEFAULT 0,
            completed_count INTEGER NOT NULL DEFAULT 0,
            failed_count INTEGER NOT NULL DEFAULT 0,
            current_file TEXT,
            is_paused INTEGER NOT NULL DEFAULT 0,
            finished_at REAL,
            updated_at REAL NOT NULL
        )
        """,
        "CREATE INDEX idx_processing_sessions_updated ON processing_sessions(updated_at DESC)"
    ]

    private static let migration10 = [
        "ALTER TABLE documents ADD COLUMN content_type TEXT NOT NULL DEFAULT 'pdf'",
        """
        CREATE TABLE mail_import_sources (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source_key TEXT NOT NULL UNIQUE,
            display_name TEXT NOT NULL,
            source_format TEXT NOT NULL,
            source_path TEXT NOT NULL,
            archived_path TEXT,
            bookmark_data BLOB,
            import_mode TEXT NOT NULL,
            source_status TEXT NOT NULL,
            mailbox_name TEXT,
            watch_enabled INTEGER NOT NULL DEFAULT 0,
            move_processed_enabled INTEGER NOT NULL DEFAULT 0,
            source_fingerprint TEXT,
            last_access_at REAL,
            last_imported_at REAL,
            last_synchronized_at REAL,
            message_count INTEGER NOT NULL DEFAULT 0,
            attachment_count INTEGER NOT NULL DEFAULT 0,
            error_count INTEGER NOT NULL DEFAULT 0,
            storage_bytes INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        )
        """,
        """
        CREATE TABLE emails (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            document_id INTEGER NOT NULL UNIQUE REFERENCES documents(id) ON DELETE CASCADE,
            stable_identity TEXT NOT NULL UNIQUE,
            message_id TEXT,
            conversation_id TEXT,
            subject TEXT NOT NULL,
            sender_name TEXT,
            sender_address TEXT,
            sent_at REAL,
            received_at REAL,
            priority TEXT NOT NULL,
            in_reply_to TEXT,
            message_references TEXT NOT NULL,
            original_text TEXT NOT NULL,
            normalized_text TEXT NOT NULL,
            html_text TEXT,
            character_set TEXT,
            raw_sha256 TEXT NOT NULL,
            source_status TEXT NOT NULL,
            attachment_count INTEGER NOT NULL DEFAULT 0,
            processing_status TEXT NOT NULL,
            index_status TEXT NOT NULL,
            imported_at REAL NOT NULL,
            last_synchronized_at REAL NOT NULL
        )
        """,
        """
        CREATE TABLE email_recipients (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            email_id INTEGER NOT NULL REFERENCES emails(id) ON DELETE CASCADE,
            role TEXT NOT NULL,
            display_name TEXT,
            address TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE email_source_links (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            email_id INTEGER NOT NULL REFERENCES emails(id) ON DELETE CASCADE,
            source_id INTEGER NOT NULL REFERENCES mail_import_sources(id) ON DELETE CASCADE,
            source_entry_key TEXT NOT NULL,
            source_present INTEGER NOT NULL DEFAULT 1,
            first_seen_at REAL NOT NULL,
            last_seen_at REAL NOT NULL,
            removed_at REAL,
            UNIQUE(source_id, source_entry_key)
        )
        """,
        """
        CREATE TABLE email_attachments (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            document_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            sha256 TEXT NOT NULL UNIQUE,
            canonical_file_name TEXT NOT NULL,
            mime_type TEXT NOT NULL,
            byte_count INTEGER NOT NULL,
            is_inline INTEGER NOT NULL DEFAULT 0,
            archived_path TEXT,
            extracted_text TEXT,
            processing_status TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        )
        """,
        """
        CREATE TABLE email_attachment_links (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            email_id INTEGER NOT NULL REFERENCES emails(id) ON DELETE CASCADE,
            attachment_id INTEGER NOT NULL REFERENCES email_attachments(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL,
            file_name TEXT NOT NULL,
            content_id TEXT,
            UNIQUE(email_id, attachment_id, ordinal)
        )
        """,
        """
        CREATE TABLE storage_migrations (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            source_path TEXT NOT NULL,
            destination_path TEXT NOT NULL,
            state TEXT NOT NULL,
            copied_files INTEGER NOT NULL DEFAULT 0,
            total_files INTEGER NOT NULL DEFAULT 0,
            copied_bytes INTEGER NOT NULL DEFAULT 0,
            total_bytes INTEGER NOT NULL DEFAULT 0,
            last_error TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            completed_at REAL
        )
        """,
        "CREATE INDEX idx_emails_message_id ON emails(message_id)",
        "CREATE INDEX idx_emails_conversation ON emails(conversation_id)",
        "CREATE INDEX idx_email_recipients_address ON email_recipients(address, role)",
        "CREATE INDEX idx_email_source_links_source ON email_source_links(source_id, source_present)",
        "CREATE INDEX idx_email_attachment_links_email ON email_attachment_links(email_id)",
        "CREATE INDEX idx_documents_content_type ON documents(content_type)",
        """
        CREATE VIEW search_source_metadata AS
        SELECT d.id AS document_id,
               l.file_name AS file_name,
               l.absolute_path AS absolute_path,
               l.relative_path AS relative_path,
               'pdf' AS content_type,
               NULL AS mail_subject,
               NULL AS mail_sender,
               NULL AS mail_date,
               NULL AS mailbox,
               NULL AS parent_email_subject,
               NULL AS parent_email_sender,
               NULL AS parent_email_date
        FROM documents d
        JOIN document_locations l
          ON l.document_id = d.id AND l.deleted_at IS NULL
        UNION ALL
        SELECT d.id,
               e.subject,
               COALESCE(s.archived_path, s.source_path, ''),
               COALESCE(s.mailbox_name, s.display_name, 'Nur Indexdaten'),
               'email',
               e.subject,
               e.sender_address,
               COALESCE(e.sent_at, e.received_at),
               COALESCE(s.mailbox_name, s.display_name),
               NULL,
               NULL,
               NULL
        FROM documents d
        JOIN emails e ON e.document_id = d.id
        LEFT JOIN email_source_links sl ON sl.email_id = e.id
        LEFT JOIN mail_import_sources s ON s.id = sl.source_id
        UNION ALL
        SELECT d.id,
               al.file_name,
               COALESCE(a.archived_path, s.source_path, ''),
               COALESCE(s.mailbox_name, s.display_name, 'E-Mail-Anhang'),
               'emailAttachment',
               NULL,
               NULL,
               NULL,
               COALESCE(s.mailbox_name, s.display_name),
               e.subject,
               e.sender_address,
               COALESCE(e.sent_at, e.received_at)
        FROM documents d
        JOIN email_attachments a ON a.document_id = d.id
        JOIN email_attachment_links al ON al.attachment_id = a.id
        JOIN emails e ON e.id = al.email_id
        LEFT JOIN email_source_links sl ON sl.email_id = e.id
        LEFT JOIN mail_import_sources s ON s.id = sl.source_id
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
