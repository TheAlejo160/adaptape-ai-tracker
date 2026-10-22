import SwiftUI

struct PanelView: View {
    @Environment(LoginItem.self) private var loginItem
    @Environment(UsageStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contentHeight: CGFloat = 0
    @State private var isVisible = false
    @State private var showingAccounts = false
    @State private var selectedTab = "quotas"

    var body: some View {
        VStack(spacing: 0) {
            if showingAccounts {
                AccountsView { showingAccounts = false }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    Picker("Vista", selection: $selectedTab) {
                        Text("Cuotas").tag("quotas")
                        Text("Gráficos").tag("history")
                        Text("Planificar").tag("planning")
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    if selectedTab == "quotas" && store.providers.isEmpty && !store.isRefreshing {
                        emptyState
                    } else {
                        providerList
                    }
                    Divider()
                    footer
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(width: 360)
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.1), value: showingAccounts)
        .environment(\.isPanelVisible, isVisible)
        // onAppear fires once; the panel window turns key on every open and resigns on close.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            isVisible = true
            loginItem.refresh()
            store.refreshIfStale()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            isVisible = false
        }
    }

    private var providerList: some View {
        ScrollView {
            VStack(spacing: 8) {
                if selectedTab == "history" {
                    if store.demoMode {
                        ContentUnavailableView("Historial real oculto en modo demo", systemImage: "chart.xyaxis.line",
                                               description: Text("Desactiva el modo demo para ver los registros de este Mac."))
                    } else {
                        HistoryView(samples: store.history, error: store.historyError)
                    }
                } else if selectedTab == "planning" {
                    PlanningView(providers: store.providers)
                } else {
                    ForEach(ProviderKind.allCases) { kind in
                        let providers = store.providers(of: kind)
                        if !providers.isEmpty {
                            ProviderSection(kind: kind, providers: providers)
                        }
                    }
                }
            }
            .padding(8)
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { contentHeight = $0 }
        }
        // ScrollView has no intrinsic height in a self-sizing window: fit content, cap at 520.
        .frame(height: min(contentHeight, 520))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Ninguna IA conectada", systemImage: "sparkles")
        } description: {
            Text("No se encontró ninguna herramienta instalada. Conecta una cuenta o activa el modo demo.")
        } actions: {
            Button("Conectar cuentas") { showingAccounts = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private var updatedText: String {
        guard let date = store.lastUpdated else { return "Cargando…" }
        return "Actualizado \(date.formatted(.relative(presentation: .named).locale(Locale(identifier: "es"))))"
    }

    private var header: some View {
        HStack(spacing: 8) {
            BrandIcon()
            VStack(alignment: .leading, spacing: 2) {
                Text("AdaptaPE AI Tracker").font(.headline)
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(updatedText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer()
            Button {
                showingAccounts = true
            } label: {
                Image(systemName: "person.crop.circle.badge.plus").frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(",")
            .help("Cuentas y conexiones (⌘,)")
            .accessibilityLabel("Cuentas y conexiones")
            Button {
                Task { await store.refresh() }
            } label: {
                refreshIcon
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("r")
            .disabled(store.isRefreshing)
            .help("Actualizar (⌘R)")
            .accessibilityLabel(store.isRefreshing ? "Actualizando" : "Actualizar")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var refreshIcon: some View {
        let icon = Image(systemName: "arrow.clockwise").frame(width: 16, height: 16)
        if #available(macOS 15, *) {
            icon.symbolEffect(.rotate, isActive: store.isRefreshing && !reduceMotion)
        } else {
            icon
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Abrir al iniciar sesión", isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.setEnabled($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help(loginItem.lastError ?? "Inicia AdaptaPE AI Tracker en segundo plano al encender el Mac")

            if loginItem.needsApproval {
                Button("Aprobar", systemImage: "exclamationmark.triangle.fill") {
                    loginItem.setEnabled(true)
                }
                .buttonStyle(.link)
                .foregroundStyle(.orange)
                .help("Bloqueado en Ajustes del Sistema › Ítems de inicio. Pulsa para abrirlo.")
            }

            Spacer()

            Button("Salir", systemImage: "power") { NSApp.terminate(nil) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
                .help("Salir de AdaptaPE AI Tracker (⌘Q)")
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// Collapsible group of providers of one kind; collapsed state survives relaunch.
private struct ProviderSection: View {
    let kind: ProviderKind
    let providers: [ProviderUsage]
    @AppStorage private var collapsed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(kind: ProviderKind, providers: [ProviderUsage]) {
        self.kind = kind
        self.providers = providers
        _collapsed = AppStorage(wrappedValue: false, "section.collapsed.\(kind.rawValue)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.15)) {
                    collapsed.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Text(kind.title).font(.subheadline.weight(.semibold))
                    Text("\(providers.count)")
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(kind.title), \(providers.count)")
            .accessibilityValue(collapsed ? "Contraído" : "Expandido")
            .accessibilityAddTraits(.isHeader)

            if !collapsed {
                VStack(spacing: 4) {
                    ForEach(providers) { ProviderRow(provider: $0) }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
    }
}
