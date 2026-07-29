import CoreGraphics
import Foundation
import Testing
@testable import FindoraCore

@Test
func bundledDocumentVisionModelIsPinnedLocalAndEightGigabyteCompatible() throws {
    let catalog = try ModelCatalog.bundled()
    let model = try #require(
        catalog.models.first { $0.kind == .documentVision }
    )

    #expect(model.id == "mlx-community/GLM-OCR-4bit")
    #expect(model.backend == "mlx-vlm")
    #expect(model.modelVersion == "97f587506984cc92fa69b2694b4128e53db6b081")
    #expect(model.downloadSizeBytes == 1_254_095_421)
    #expect(model.minimumSystemRAMBytes == 8_589_934_592)
    #expect(model.licenseName == "MIT")
    #expect(model.files.count == 9)
    #expect(model.files.allSatisfy {
        $0.downloadURL.scheme == "https"
            && $0.downloadURL.host == "huggingface.co"
            && $0.checksumSHA256.count == 64
    })
}

@Test
func documentModelIntegrityFailureIsVisibleBeforeActivation() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "FindoraModelIntegrity-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        applicationSupport: root.appending(path: "Support"),
        logs: root.appending(path: "Logs")
    )
    let config = Data(#"{"model_type":"glm_ocr"}"#.utf8)
    let weights = Data([1, 2, 3, 4])
    let hasher = SHA256Hasher()
    let descriptor = LocalModelDescriptor(
        id: "local/fixture",
        kind: .documentVision,
        displayName: "Fixture",
        family: "Fixture",
        parameters: "tiny",
        quantization: "none",
        backend: "mlx-vlm",
        downloadSizeBytes: Int64(config.count + weights.count),
        estimatedRuntimeRAMBytes: 1,
        minimumSystemRAMBytes: 1,
        recommendedSystemRAMBytes: 1,
        defaultContextLength: 512,
        maximumContextLength: 512,
        downloadURL: URL(string: "https://huggingface.co/local/fixture")!,
        checksumSHA256: String(repeating: "0", count: 64),
        licenseName: "MIT",
        licenseURL: URL(string: "https://huggingface.co/local/fixture/LICENSE")!,
        modelVersion: "fixture-v1",
        repositoryID: "local/fixture",
        files: [
            ModelFile(
                relativePath: "config.json",
                downloadURL: URL(string: "https://huggingface.co/local/fixture/config.json")!,
                sizeBytes: Int64(config.count),
                checksumSHA256: hasher.hash(data: config)
            ),
            ModelFile(
                relativePath: "model.safetensors",
                downloadURL: URL(string: "https://huggingface.co/local/fixture/model.safetensors")!,
                sizeBytes: Int64(weights.count),
                checksumSHA256: hasher.hash(data: weights)
            ),
        ]
    )
    let directory = paths.models
        .appending(path: "local_fixture")
        .appending(path: descriptor.modelVersion)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    try config.write(to: directory.appending(path: "config.json"))
    try Data([4, 3, 2, 1]).write(
        to: directory.appending(path: "model.safetensors")
    )
    let manager = LocalModelManager(
        catalog: ModelCatalog(schemaVersion: 1, models: [descriptor]),
        paths: paths
    )
    let profile = HardwareProfile(
        isAppleSilicon: true,
        chipName: "Test",
        physicalMemoryBytes: 8_589_934_592,
        availableStorageBytes: 10_000_000
    )

    let corrupt = try #require(await manager.models(profile: profile).first)
    #expect(!corrupt.isInstalled)
    #expect(corrupt.integrityFailed)
    await #expect(throws: Error.self) {
        try await manager.activate(modelID: descriptor.id)
    }

    try weights.write(to: directory.appending(path: "model.safetensors"))
    let repaired = try #require(await manager.models(profile: profile).first)
    #expect(repaired.isInstalled)
    #expect(!repaired.integrityFailed)
    try await manager.activate(modelID: descriptor.id)
    #expect(await manager.activeModel(kind: .documentVision)?.id == descriptor.id)
    await manager.deactivate(kind: .documentVision)
    #expect(await manager.activeModel(kind: .documentVision) == nil)
}

@Test
func ocrBoundingBoxesMapIntoOffsetPDFMediaBoxWithoutChangingThePage() {
    let box = OCRTextBox(
        pageNumber: 2,
        text: "Rechnungsnummer",
        normalizedX: 0.25,
        normalizedY: 0.50,
        normalizedWidth: 0.20,
        normalizedHeight: 0.10,
        confidence: 0.95
    )
    let mediaBox = CGRect(x: 18, y: 36, width: 600, height: 800)

    let rect = PDFHighlightGeometry.pageRect(
        normalized: box,
        in: mediaBox
    )

    #expect(rect.origin.x == 168)
    #expect(rect.origin.y == 436)
    #expect(rect.width == 120)
    #expect(rect.height == 80)
    #expect(mediaBox == CGRect(x: 18, y: 36, width: 600, height: 800))
}

@Test
func visionBoundingBoxesReturnToTheSamePagePositionForEveryRotation() {
    let upright = CGRect(x: 0.08, y: 0.86, width: 0.72, height: 0.03)
    let rotatedRight = CGRect(x: 0.86, y: 0.20, width: 0.03, height: 0.72)
    let upsideDown = CGRect(x: 0.20, y: 0.11, width: 0.72, height: 0.03)
    let rotatedLeft = CGRect(x: 0.11, y: 0.08, width: 0.03, height: 0.72)

    let results = [
        VisionOCRGeometry.unrotated(upright, rotationDegrees: 0),
        VisionOCRGeometry.unrotated(rotatedRight, rotationDegrees: 90),
        VisionOCRGeometry.unrotated(upsideDown, rotationDegrees: 180),
        VisionOCRGeometry.unrotated(rotatedLeft, rotationDegrees: 270),
    ]

    for result in results {
        #expect(abs(result.minX - upright.minX) < 0.000_001)
        #expect(abs(result.minY - upright.minY) < 0.000_001)
        #expect(abs(result.width - upright.width) < 0.000_001)
        #expect(abs(result.height - upright.height) < 0.000_001)
    }
}

@Test
func croppedVisionCoordinatesMapBackToTheFullPDFPage() {
    let crop = CGRect(x: 0.01, y: 0.01, width: 0.98, height: 0.98)
    let croppedBox = CGRect(x: 0.25, y: 0.50, width: 0.20, height: 0.10)

    let result = VisionOCRGeometry.mapToFullPage(
        croppedBox,
        renderedContentRect: crop
    )

    #expect(abs(result.minX - 0.255) < 0.000_001)
    #expect(abs(result.minY - 0.50) < 0.000_001)
    #expect(abs(result.width - 0.196) < 0.000_001)
    #expect(abs(result.height - 0.098) < 0.000_001)
}

@Test
func pdfKitTextAssessmentRejectsCharacterNoiseButAcceptsIdentifiers() throws {
    let extractor = PDFKitTextExtractor()
    let identifier = extractor.assessTextLayer(
        pageNumber: 1,
        text: "RE-2026-004281",
        selectionAvailable: true
    )
    let noise = extractor.assessTextLayer(
        pageNumber: 2,
        text: "��������������������������������",
        selectionAvailable: true
    )

    #expect(identifier.isUsable)
    #expect(identifier.classification == .usable)
    #expect(!noise.isUsable)
    #expect(noise.classification == .corrupt)
}
