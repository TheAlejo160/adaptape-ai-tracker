import SwiftUI

/// Connection status and consent to direct Keychain reads.
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
            Label("El tracker no guarda credenciales. «agy /quota» gestiona su propia sesión. Solo guardamos preferencias, iconos y la espera entre consultas.",
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
        case .keychainConsent, .optionalKeychainConsent:
            Toggle("", isOn: Binding(
                get: { store.enabledIDs.contains(info.id) },
                set: { store.setEnabled($0, id: info.id) }
            ))
            .labelsHidden()
            .accessibilityLabel("Permitir lectura del Llavero de \(info.name)")
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
        case .keychainConsent, .optionalKeychainConsent:
            let tool = info.id == "gemini" ? "agy" : "claude"
            let usage = store.providers.first { $0.id == info.id }
            if info.id == "gemini", usage?.quotaSource == "Cuota de «agy /quota»" {
                return "\(usage?.quotaStatus ?? "Consultando cuota…") · «agy /quota»"
            }
            if info.id == "claude", !store.enabledIDs.contains(info.id), usage?.windows.isEmpty == false {
                return "\(usage?.quotaStatus ?? "Cuota recibida") · registro local"
            }
            return store.enabledIDs.contains(info.id)
                ? "\(usage?.quotaStatus ?? "Consultando cuota…") · «\(tool)»"
                : "Activa para permitir el Llavero de «\(tool)»"
        case .apiKeyEnv(let variable):
            return isDetected ? "Detectado (variable \(variable))" : "Define la variable \(variable)"
        }
    }
}
