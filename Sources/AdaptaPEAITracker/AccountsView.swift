import SwiftUI

/// Read-only account panel: shows how each provider is detected. Nothing is stored or typed here —
/// the app only reads credentials other tools already saved. The one control is the macOS-consent
/// toggle for providers whose token lives in another app's Keychain.
struct AccountsView: View {
    let onClose: () -> Void
    @Environment(UsageStore.self) private var store
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(ProviderKind.allCases) { kind in
                        let connectors = store.available.filter { $0.info.kind == kind }
                        if !connectors.isEmpty {
                            section(kind, connectors)
                        }
                    }
                }
                .padding(8)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { contentHeight = $0 }
            }
            .frame(height: min(contentHeight, 440))
            Divider()
            footer($store)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onClose) {
                Image(systemName: "chevron.left").frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help("Volver (⎋)")
            .accessibilityLabel("Volver")
            Text("Cuentas").font(.headline).accessibilityAddTraits(.isHeader)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func footer(_ store: Bindable<UsageStore>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Modo demo (datos de ejemplo)", isOn: store.demoMode)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.callout)
            Label("No se guarda ninguna credencial: la app solo lee los tokens que tus herramientas ya tienen en este Mac, los usa en memoria y los envía solo a cada proveedor. En disco guarda solo tus preferencias y la caché de iconos.",
                  systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func section(_ kind: ProviderKind, _ connectors: [any UsageConnector]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kind.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            ForEach(connectors, id: \.info.id) { connector in
                AccountRow(info: connector.info)
            }
        }
    }
}

/// One provider's connection state. `.keychainConsent` gets a toggle; the rest are informational.
private struct AccountRow: View {
    let info: ProviderInfo
    @Environment(UsageStore.self) private var store

    private var isDetected: Bool { store.providers.contains { $0.id == info.id } }

    var body: some View {
        HStack(spacing: 10) {
            ProviderIcon(url: info.iconURL, name: info.name, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(info.name).font(.body)
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .opacity(dimmed ? 0.55 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(info.name), \(statusText)")
    }

    @ViewBuilder private var trailing: some View {
        switch info.auth {
        case .keychainConsent:
            Toggle("", isOn: Binding(
                get: { store.isEnabled(info) },
                set: { store.setEnabled($0, id: info.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("macOS pedirá permiso para leer el token del Llavero")
        case .automatic where isDetected, .apiKeyEnv where isDetected:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                .accessibilityHidden(true)
        default:
            EmptyView()
        }
    }

    private var dimmed: Bool {
        switch info.auth {
        case .keychainConsent: !store.isEnabled(info)
        default: !isDetected && !store.demoMode
        }
    }

    private var statusText: String {
        if store.demoMode { return "No comprobado en modo demo" }
        switch info.auth {
        case .automatic:
            return isDetected ? "Detectado automáticamente" : "No encontrado en este Mac"
        case .keychainConsent:
            return store.isEnabled(info)
                ? (isDetected ? "Conectado (token del Llavero)" : "Activado; esperando permiso del Llavero")
                : "Activa para leer el token del Llavero"
        case .apiKeyEnv(let variable):
            return isDetected ? "Detectado (variable \(variable))" : "Define la variable \(variable)"
        }
    }
}
