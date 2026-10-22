import SwiftUI

/// Every connector the app knows, how it gets its data, and the switch to link or unlink it.
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
            // Same self-sizing trick as the provider list; header + footer keep the panel under ~560.
            .frame(height: min(contentHeight, 440))
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Modo demo (datos de ejemplo)", isOn: $store.demoMode)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.callout)
                Label("Los tokens se guardan solo en tu Llavero y nunca salen de este Mac salvo hacia el propio proveedor.",
                      systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
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

    private func section(_ kind: ProviderKind, _ connectors: [any UsageConnector]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kind.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .accessibilityAddTraits(.isHeader)
            ForEach(connectors, id: \.info.id) { AccountRow(connector: $0) }
        }
    }
}

/// One connector: icon, name, where its data comes from, and the control to link it.
private struct AccountRow: View {
    let connector: any UsageConnector
    @Environment(UsageStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var editingKey = false
    @State private var keyText = ""
    @State private var saveFailed = false
    @State private var deleteFailed = false
    @FocusState private var keyFocused: Bool

    private var info: ProviderInfo { connector.info }
    private var keyAccount: String { "apikey.\(info.id)" }
    private var current: ProviderUsage? { store.providers.first { $0.id == info.id } }
    private var isDetected: Bool { current != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProviderIcon(url: info.iconURL, name: info.name, size: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.name).font(.body.weight(.medium))
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if deleteFailed {
                        Label("No se pudo borrar del Llavero", systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if let error = current?.error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                control
            }
            if editingKey {
                keyEditor.transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? AnyShapeStyle(.fill.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8))
        .opacity(info.auth == .automatic && !store.demoMode && !isDetected ? 0.55 : 1)
        .clipped()
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(info.name)
    }

    // MARK: Per-auth content

    private var isConnected: Bool {
        switch info.auth {
        case .automatic: isDetected
        case .keychainConsent: store.isEnabled(info)
        case .webLogin: store.isEnabled(info) && WebSession.isLinked(info.id)
        case .apiKey: store.isEnabled(info) && KeychainStore.load(account: keyAccount) != nil
        }
    }

    private var caption: String {
        switch info.auth {
        case .automatic:
            // Demo mode shows sample data and skips detection, so "not found" would be a lie.
            store.demoMode ? "No comprobado en modo demo"
                : isDetected ? "Detectado automáticamente" : "No encontrado en este Mac"
        case .keychainConsent: "Usa el token guardado por la herramienta (Llavero)"
        case .webLogin: isConnected ? "Cuenta vinculada" : "Vincula tu cuenta iniciando sesión"
        case .apiKey: isConnected ? "Clave API guardada en el Llavero" : "Con tu clave API oficial"
        }
    }

    @ViewBuilder private var control: some View {
        switch info.auth {
        case .automatic:
            EmptyView()
        case .keychainConsent:
            Toggle("Usar \(info.name)", isOn: Binding(
                get: { store.isEnabled(info) },
                set: { store.setEnabled($0, id: info.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("macOS pedirá permiso para leer el token que guardó la herramienta")
        case .webLogin, .apiKey:
            if isConnected {
                Button("Desconectar", action: disconnect)
                    .controlSize(.small)
                    .accessibilityLabel("Desconectar \(info.name)")
            } else {
                Button(editingKey ? "Cancelar" : "Conectar", action: connect)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(editingKey ? Color.secondary : Color.accentColor)
                    .accessibilityLabel(editingKey ? "Cancelar" : "Conectar \(info.name)")
            }
        }
    }

    private var keyEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                SecureField("Pega tu clave API", text: $keyText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($keyFocused)
                    .onSubmit(saveKey)
                    .accessibilityLabel("Clave API de \(info.name)")
                Button("Guardar", action: saveKey)
                    .controlSize(.small)
                    .disabled(trimmedKey.isEmpty)
                    .accessibilityLabel("Guardar clave de \(info.name)")
            }
            if saveFailed {
                Text("No se pudo guardar en el Llavero").font(.caption).foregroundStyle(.orange)
            }
        }
        .onAppear { keyFocused = true }
    }

    // MARK: Actions

    private var trimmedKey: String { keyText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func connect() {
        switch info.auth {
        case .webLogin:
            guard let connector = connector as? any WebLoginConnector else { return }
            let store = store
            let id = info.id
            deleteFailed = false
            WebLogin.present(for: connector) { ok in
                if ok { store.setEnabled(true, id: id) }
            }
        case .apiKey:
            withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.15)) {
                editingKey.toggle()
            }
            keyText = ""
            saveFailed = false
            deleteFailed = false
        default:
            break
        }
    }

    private func saveKey() {
        guard !trimmedKey.isEmpty else { return }
        do {
            try KeychainStore.save(Data(trimmedKey.utf8), account: keyAccount)
        } catch {
            saveFailed = true
            return
        }
        keyText = ""
        withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.15)) {
            editingKey = false
        }
        store.setEnabled(true, id: info.id)
    }

    private func disconnect() {
        let deleted = if case .webLogin = info.auth { WebSession.unlink(info.id) } else { KeychainStore.delete(account: keyAccount) }
        // A secret left in the Keychain would quietly reconnect later: stay connected and say so.
        deleteFailed = !deleted
        guard deleted else { return }
        store.setEnabled(false, id: info.id)
    }
}
