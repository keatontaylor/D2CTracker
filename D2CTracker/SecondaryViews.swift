import CoreLocation
import SwiftUI
import UIKit
import D2CTrackerCore

struct MoreView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var connectivity: ConnectivityMonitor
    @EnvironmentObject private var location: LocationService
    @EnvironmentObject private var linkQuality: LinkQualityService
    @EnvironmentObject private var terrain: TerrainService
    @State private var confirmTerrainRemoval = false
    @State private var confirmCellularTerrainDownload = false
    @State private var diagnosticExport: DiagnosticExportFile?
    @State private var diagnosticExportError: String?

    var body: some View {
        ZStack {
            AppBackdrop()
            List {
                dataSection
                locationSection
                terrainSection
                linkQualitySection
                legalSection
                privacySection
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Data & Settings")
        .preferredColorScheme(.dark)
        .task {
            await terrain.prepareSelectedState()
            terrain.refreshStoragePreflight()
        }
        .sheet(item: $diagnosticExport) { export in
            ShareSheet(items: [export.url])
        }
        .confirmationDialog(
            "Remove all downloaded terrain?",
            isPresented: $confirmTerrainRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove terrain", role: .destructive) { terrain.removeDownloadedTerrain() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The offline state pack and its cached elevation tiles will be deleted.")
        }
        .confirmationDialog(
            "Download terrain over cellular?",
            isPresented: $confirmCellularTerrainDownload,
            titleVisibility: .visible
        ) {
            Button("Download over cellular") { terrain.downloadSelectedState() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The remaining \(terrain.selectedState.name) download is estimated at \(ByteCountFormatter.string(fromByteCount: terrain.remainingEstimatedBytes, countStyle: .file)). Carrier data charges may apply.")
        }
    }

    private var dataSection: some View {
        Section("Orbital data") {
            LabeledContent("Source", value: model.usesBundledSample ? "Bundled development sample" : "CelesTrak GP JSON")
            LabeledContent("Catalog", value: "\(model.catalog?.records.count ?? 0) records")
            LabeledContent("Fetched", value: model.catalog?.fetchedAt.formatted(date: .abbreviated, time: .shortened) ?? "Never")
            LabeledContent("Catalog fetch", value: model.freshness?.rawValue.capitalized ?? "Unknown")
            LabeledContent("Representative TLE age") {
                Text(model.representativeTLEAgeSeconds.map(compactAge) ?? "Unknown")
                    .monospacedDigit()
            }
            InputStatusBadges(statuses: [model.tleInputStatus, model.servingInputStatus])
            Button {
                Task { await model.refresh() }
            } label: {
                HStack {
                    Label("Refresh catalog", systemImage: "arrow.clockwise")
                    Spacer()
                    if model.isRefreshing { ProgressView() }
                }
            }
            .disabled(!model.canRefreshCatalog)
            if !connectivity.mode.permitsCatalogRefresh {
                Label("Downloads are disabled on \(connectivity.mode.displayName.lowercased()) connectivity.", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.orange)
            } else if let nextAllowedAt = model.nextCatalogRequestAllowedAt, nextAllowedAt > .now {
                LabeledContent("Next request allowed") {
                    Text(nextAllowedAt.formatted(date: .abbreviated, time: .shortened))
                        .monospacedDigit()
                }
                Text("CelesTrak requests are limited to one attempt every two hours, including manual refreshes and failed requests.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var locationSection: some View {
        Section("Observer location") {
            Toggle("Use manual location", isOn: $model.usesManualLocation)
                .onChange(of: model.usesManualLocation) { _, usesManual in
                    if !usesManual, location.authorization == .notDetermined {
                        location.requestLocationAccess()
                    }
                }
            if model.usesManualLocation {
                LabeledContent("Latitude") {
                    TextField("Latitude", value: $model.manualLatitude, format: .number.precision(.fractionLength(4)))
                        .multilineTextAlignment(.trailing).keyboardType(.numbersAndPunctuation)
                }
                LabeledContent("Longitude") {
                    TextField("Longitude", value: $model.manualLongitude, format: .number.precision(.fractionLength(4)))
                        .multilineTextAlignment(.trailing).keyboardType(.numbersAndPunctuation)
                }
            } else if location.authorization == .notDetermined {
                Label("Waiting for location permission", systemImage: "location.circle")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Allow GPS location") { location.requestLocationAccess() }
            } else if location.authorization == .denied || location.authorization == .restricted {
                Label("GPS access is unavailable. Enable manual location or allow access in Settings.", systemImage: "location.slash")
                    .font(.caption).foregroundStyle(.secondary)
            } else if location.location == nil {
                Label("Acquiring current GPS location…", systemImage: "location.magnifyingglass")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                LabeledContent("Accuracy", value: location.isReducedAccuracy ? "Approximate" : "Precise")
                LabeledContent("Source", value: "Current GPS location")
            }
            Text("Location is used only on-device for azimuth, elevation, range, and pass calculations.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var terrainSection: some View {
        Section("Offline terrain & line of sight") {
            Toggle("Use terrain horizon", isOn: $terrain.isEnabled)

            InputStatusBadges(statuses: [terrain.coverageInputStatus])

            Picker("State pack", selection: $terrain.selectedStateID) {
                ForEach(USStateRegion.all) { state in
                    Text(state.name).tag(state.id)
                }
            }
            .onChange(of: terrain.selectedStateID) { _, _ in
                Task { await terrain.prepareSelectedState() }
            }
            .disabled(terrain.activity == .downloading)

            if terrain.activity == .loadingBoundary || terrain.activity == .planning {
                HStack {
                    Text(terrain.activity.label)
                    Spacer()
                    ProgressView()
                }
            } else if terrain.plannedTileCount > 0 {
                LabeledContent("Estimated download") {
                    Text(ByteCountFormatter.string(fromByteCount: terrain.estimatedBytes, countStyle: .file))
                        .monospacedDigit()
                }
                LabeledContent("Skadi cells", value: terrain.plannedTileCount.formatted())
                if terrain.cachedTileCount > 0 {
                    LabeledContent(
                        terrain.hasResumableDownload ? "Cached resume point" : "Cached tiles",
                        value: "\(terrain.cachedTileCount.formatted()) of \(terrain.plannedTileCount.formatted())"
                    )
                }
                LabeledContent("Remaining download") {
                    Text(ByteCountFormatter.string(fromByteCount: terrain.remainingEstimatedBytes, countStyle: .file))
                        .monospacedDigit()
                }
                if let available = terrain.availableStorageBytes {
                    LabeledContent("Storage available") {
                        Text(ByteCountFormatter.string(fromByteCount: available, countStyle: .file))
                            .monospacedDigit()
                            .foregroundStyle(terrain.hasSufficientStorage ? Color.primary : Color.orange)
                    }
                }
                if !terrain.hasSufficientStorage {
                    Label(
                        "More free space is required. The preflight includes a 256 MB safety reserve.",
                        systemImage: "externaldrive.badge.exclamationmark"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                Text("AWS Skadi HGT · approximately 30 m · stored compressed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if terrain.activity == .downloading {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: terrain.progress)
                    HStack {
                        Text(terrain.progressLabel)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: terrain.downloadedBytes, countStyle: .file))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                Button("Pause download") { terrain.cancelDownload() }
            } else {
                Button {
                    beginTerrainDownload()
                } label: {
                    HStack {
                        Label(
                            terrain.hasPackForSelectedState
                                ? "Update \(terrain.selectedState.name) pack"
                                : terrain.cachedTileCount > 0
                                    ? "Resume \(terrain.selectedState.name) download"
                                    : "Download \(terrain.selectedState.name)",
                            systemImage: "square.and.arrow.down"
                        )
                        Spacer()
                        if terrain.activity == .buildingHorizon { ProgressView() }
                    }
                }
                .disabled(
                    terrain.isBusy
                        || !terrainDownloadEligible
                        || terrain.plannedTileCount == 0
                        || !terrain.hasSufficientStorage
                )
            }

            if let pack = terrain.pack {
                LabeledContent("Installed pack", value: pack.state.name)
                LabeledContent(
                    "Stored terrain",
                    value: ByteCountFormatter.string(fromByteCount: pack.actualBytes, countStyle: .file)
                )
                LabeledContent("Downloaded", value: pack.downloadedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Local horizon") {
                    Text(terrain.horizonProfile == nil ? "Waiting for a location in the state" : "Active")
                        .foregroundStyle(terrain.horizonProfile == nil ? Color.secondary : Color.green)
                }
                Button("Remove downloaded terrain", role: .destructive) {
                    confirmTerrainRemoval = true
                }
            }

            if !terrainDownloadEligible {
                Label(terrainDownloadRestrictionText, systemImage: "wifi.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let message = terrain.statusMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if let message = terrain.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                Button("Recheck estimate and storage") {
                    Task {
                        await terrain.prepareSelectedState()
                        terrain.refreshStoragePreflight()
                    }
                }
                .disabled(terrain.isBusy)
            }
            Text("The pack keeps approximately 30 m terrain throughout the selected state plus a 30-mile service-range margin. Skadi cells stay gzip-compressed until needed for a local horizon calculation. It models terrain, not buildings or trees.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var terrainDownloadEligible: Bool {
        switch connectivity.mode {
        case .wifi, .wiredEthernet, .terrestrialCellular: true
        case .constrained, .ultraConstrained, .offline, .unknown: false
        }
    }

    private var terrainDownloadRestrictionText: String {
        switch connectivity.mode {
        case .ultraConstrained:
            "Terrain downloads are blocked on ultra-constrained satellite networks."
        case .constrained:
            "Terrain downloads are blocked on constrained networks."
        case .offline:
            "Connect to Wi-Fi, Ethernet, or regular cellular to download terrain."
        case .unknown:
            "Waiting for the network type before allowing a terrain download."
        case .wifi, .wiredEthernet, .terrestrialCellular:
            ""
        }
    }

    private func beginTerrainDownload() {
        switch connectivity.mode {
        case .terrestrialCellular:
            confirmCellularTerrainDownload = true
        case .wifi, .wiredEthernet:
            terrain.downloadSelectedState()
        case .constrained, .ultraConstrained, .offline, .unknown:
            break
        }
    }

    private var linkQualitySection: some View {
        Section("Internet link diagnostics") {
            Toggle("Track link quality", isOn: $linkQuality.isEnabled)

            Toggle(
                "Diagnostic mode: test any network",
                isOn: Binding(
                    get: { linkQuality.diagnosticOverride },
                    set: { value in
                        linkQuality.diagnosticOverride = value
                        if value { linkQuality.isEnabled = true }
                    }
                )
            )

            LabeledContent("Current path", value: connectivity.mode.displayName)
            LabeledContent("System link quality", value: connectivity.systemLinkQuality.rawValue.capitalized)
            LabeledContent("Probe state", value: linkQuality.statusText)
            LabeledContent("Probe target", value: "Cloudflare Speed Test")
            Picker(
                "Foreground interval",
                selection: Binding(
                    get: { linkQuality.foregroundIntervalSeconds },
                    set: { linkQuality.setForegroundInterval($0) }
                )
            ) {
                ForEach([30.0, 60, 120, 300], id: \.self) { seconds in
                    Text(intervalLabel(seconds)).tag(seconds)
                }
            }
            Picker(
                "Background interval",
                selection: Binding(
                    get: { linkQuality.backgroundIntervalSeconds },
                    set: { linkQuality.setBackgroundInterval($0) }
                )
            ) {
                ForEach([60.0, 300, 600, 900, 1_800], id: \.self) { seconds in
                    Text(intervalLabel(seconds)).tag(seconds)
                }
            }
            LabeledContent(
                "Recorded probe traffic",
                value: ByteCountFormatter.string(fromByteCount: linkQuality.recordedTrafficBytes, countStyle: .file)
            )

            if !linkQuality.samples.isEmpty {
                Button {
                    do {
                        diagnosticExportError = nil
                        diagnosticExport = DiagnosticExportFile(
                            url: try linkQuality.makePrivacyScrubbedDiagnosticExport()
                        )
                    } catch {
                        diagnosticExportError = error.localizedDescription
                    }
                } label: {
                    Label("Share TestFlight diagnostic report", systemImage: "square.and.arrow.up")
                }

                Text("The JSON report omits location, IP and device identifiers, satellite names and IDs, headings, phone orientation, absolute sample times, and raw error text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let diagnosticExportError {
                Label(diagnosticExportError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Button {
                Task { await linkQuality.runProbeNow() }
            } label: {
                HStack {
                    Label("Run fresh-connection probe", systemImage: "waveform.path.ecg")
                    Spacer()
                    if linkQuality.isProbeInFlight { ProgressView() }
                }
            }
            .disabled(
                !linkQuality.isEnabled
                    || !linkQuality.shouldProbeOnCurrentPath
                    || linkQuality.isProbeInFlight
            )

            if !linkQuality.samples.isEmpty {
                Button("Clear link history", role: .destructive) {
                    linkQuality.clearHistory()
                }
            }

            Text("Carrier-provided satellite networks appear to apps as ultra-constrained paths. Diagnostic mode exercises the same flow on Wi-Fi or terrestrial cellular. The foreground and background intervals above apply globally to every tested network. Each attempt has a five-second deadline; failures and offline paths are recorded as missed snapshots.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func intervalLabel(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds)) seconds" }
        let minutes = Int(seconds / 60)
        return "\(minutes) minute\(minutes == 1 ? "" : "s")"
    }

    private func compactAge(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded()))
        if value < 60 { return "\(value) seconds" }
        if value < 3_600 { return "\(value / 60) minutes" }
        if value < 86_400 { return String(format: "%.1f hours", Double(value) / 3_600) }
        return String(format: "%.1f days", Double(value) / 86_400)
    }

    private var privacySection: some View {
        Section("Privacy & limitations") {
            Label("No analytics or tracking SDKs", systemImage: "hand.raised.fill")
            Label("Orbital calculations stay on device", systemImage: "iphone.and.arrow.forward")
            Label("Optimized for carrier satellite networks", systemImage: "checkmark.shield")
            Text("When link diagnostics are enabled, zero-byte test requests are sent to Cloudflare. Cloudflare receives ordinary request metadata, including the public IP address used for the connection.")
                .font(.caption).foregroundStyle(.secondary)
            Text("iOS public APIs can describe the network path but do not expose a modem-confirmed serving satellite. Every candidate shown here is a geometric estimate.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var legalSection: some View {
        Section("About") {
            LabeledContent("App", value: "D2C Tracker")
            NavigationLink {
                DataSourcesLegalView()
            } label: {
                Label("Data Sources & Legal", systemImage: "doc.text.magnifyingglass")
            }
        }
    }
}

private struct DiagnosticExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct DataSourcesLegalView: View {
    var body: some View {
        List {
            Section("Independent software") {
                Text("D2C Tracker is an independent application and is not affiliated with, endorsed by, or sponsored by Space Exploration Technologies Corp., SpaceX, Starlink, any wireless carrier, CelesTrak, or the listed data providers.")
                Text("STARLINK and SPACEX are trademarks of Space Exploration Technologies Corp. Their names are used only to identify the satellite system and source context described by the app.")
                Link("SpaceX trademark guidance", destination: URL(string: "https://www.spacex.com/trademark/")!)
            }

            Section("Orbital data") {
                Text("General Perturbations orbital data provided by CelesTrak. D2C Tracker requests only the DTC-tagged records it needs and caches validated responses.")
                Link("CelesTrak", destination: URL(string: "https://celestrak.org/")!)
                Link("CelesTrak usage policy", destination: URL(string: "https://celestrak.org/usage-policy.php")!)
            }

            Section("Terrain & boundaries") {
                Text("Terrain Tiles are accessed on demand from the Registry of Open Data on AWS. United States 3DEP and SRTM terrain data courtesy of the U.S. Geological Survey.")
                Link("AWS Terrain Tiles", destination: URL(string: "https://registry.opendata.aws/terrain-tiles/")!)
                Text("State boundary data: U.S. Census Bureau, Geography Division, TIGERweb.")
                Link("U.S. Census Bureau TIGERweb", destination: URL(string: "https://tigerweb.geo.census.gov/tigerwebmain/TIGERweb_apps.html")!)
            }

            Section("Globe map data") {
                Text("Made with Natural Earth. Free vector and raster map data @ naturalearthdata.com.")
                Link("Natural Earth terms of use", destination: URL(string: "https://www.naturalearthdata.com/about/terms-of-use/")!)
            }

            Section("Connectivity diagnostics") {
                Text("Optional link diagnostics use Cloudflare’s public Speed Test download endpoint with a zero-byte payload to measure DNS, connection, TLS, time-to-first-byte, and total request timing.")
                Link("Cloudflare Speed Test project", destination: URL(string: "https://github.com/cloudflare/speedtest")!)
            }

            Section("Open-source software") {
                Text("Orbital propagation uses SatelliteKit 2.1.0 by Gavin Eadie under the MIT License.")
                Link("SatelliteKit source", destination: URL(string: "https://github.com/gavineadie/SatelliteKit")!)
                DisclosureGroup("SatelliteKit MIT License") {
                    Text(Self.satelliteKitLicense)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

            Section("Important limitations") {
                Text("Satellite identity, serving probability, RF margin, terrain clearance, and link quality are estimates. They are not modem-confirmed measurements and must not be used for navigation, emergency response, or safety-critical decisions.")
                Text("Third-party data and services remain subject to their providers’ availability, accuracy, usage policies, and terms.")
            }
        }
        .navigationTitle("Data Sources & Legal")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }

    private static let satelliteKitLicense = """
    The MIT License (MIT)

    Copyright (c) 2018-25 Gavin Eadie

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
    """
}
