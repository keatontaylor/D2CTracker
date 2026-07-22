import Foundation

public enum DirectToCellClassifier {
    /// Classifies independently from orbital parsing. Explicit manifest entries win so that
    /// reviewed exceptions and operational status can override the catalog naming convention.
    public static func classify(
        elements: OrbitalElements,
        manifestEntry: DirectToCellManifest.Entry?
    ) -> SatelliteRecord {
        if let manifestEntry {
            return SatelliteRecord(
                elements: elements,
                directToCell: manifestEntry.directToCell,
                operationalStatus: manifestEntry.status,
                generation: manifestEntry.generation,
                classificationConfidence: manifestEntry.confidence,
                classificationSource: .manifest
            )
        }

        if hasDTCTag(elements.name) {
            return SatelliteRecord(
                elements: elements,
                directToCell: true,
                operationalStatus: .unknown,
                generation: nil,
                classificationConfidence: 0.98,
                classificationSource: .gpObjectNameDTC
            )
        }

        return SatelliteRecord(
            elements: elements,
            directToCell: false,
            operationalStatus: .unknown,
            generation: nil,
            classificationConfidence: 0,
            classificationSource: .unclassified
        )
    }

    public static func hasDTCTag(_ name: String) -> Bool {
        name.uppercased()
            .split { !$0.isLetter && !$0.isNumber }
            .contains { $0 == "DTC" }
    }
}
