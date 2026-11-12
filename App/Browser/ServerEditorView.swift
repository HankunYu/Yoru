import SwiftUI

/// Sheet for adding a server or editing a saved one: choose the kind, give the address
/// (for SMB, optionally by picking a server found on the network) and sign in. The server
/// is saved only after a connection with what was entered succeeds.
struct ServerEditorView: View {
    /// The server being edited; nil to add one.
    let existing: MediaServer?

    @Environment(\.dismiss) private var dismiss
    @State private var discovery = SMBDiscovery()
    @State private var kind: MediaServer.Kind
    @State private var address: String
    @State private var name: String
    @State private var username: String
    @State private var password = ""
    @State private var isConnecting = false
    @State private var failure: String?

    init(editing existing: MediaServer? = nil) {
        self.existing = existing
        _kind = State(initialValue: existing?.kind ?? .smb)
        _address = State(initialValue: existing?.address ?? "")
        _name = State(initialValue: existing?.name ?? "")
        _username = State(initialValue: existing?.username ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                if existing == nil {
                    Picker("Type", selection: $kind) {
                        Text(verbatim: "SMB").tag(MediaServer.Kind.smb)
                        Text(verbatim: "WebDAV").tag(MediaServer.Kind.webDAV)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                if kind == .smb, existing == nil, !discovery.services.isEmpty {
                    Section("Nearby") {
                        ForEach(discovery.services) { service in
                            Button {
                                select(service)
                            } label: {
                                Label(service.name, systemImage: "server.rack")
                            }
                            .tint(.primary)
                        }
                    }
                }
                Section {
                    field("Address") {
                        TextField(
                            "Address", text: $address,
                            prompt: Text(verbatim: kind == .smb ? "nas.local" : "https://nas.local:5006/dav")
                        )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    }
                    field("Name") {
                        TextField("Name", text: $name, prompt: Text("Optional"))
                    }
                } header: {
                    Text("Server")
                }
                Section {
                    field("Username") {
                        TextField("Username", text: $username, prompt: Text("Guest"))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.username)
                    }
                    field("Password") {
                        SecureField("Password", text: $password, prompt: existing == nil ? nil : Text("Unchanged"))
                            .textContentType(.password)
                    }
                } footer: {
                    if let failure {
                        Text(failure)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(existing == nil ? "Add Server" : "Edit Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isConnecting {
                        ProgressView()
                    } else {
                        Button(existing == nil ? "Add" : "Save") { connect() }
                            .disabled(normalizedAddress.isEmpty)
                    }
                }
            }
            .disabled(isConnecting)
        }
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
    }

    /// A row naming what goes into its text field, which sits at the trailing edge.
    private func field(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        LabeledContent {
            content()
                .multilineTextAlignment(.trailing)
        } label: {
            Text(title)
        }
    }

    private var normalizedAddress: String {
        switch kind {
        case .smb: MediaServer.host(fromAddress: address)
        case .webDAV: address.trimmingCharacters(in: .whitespaces).isEmpty ? "" : MediaServer.baseURL(fromAddress: address)
        }
    }

    private func select(_ service: SMBDiscovery.Service) {
        name = service.name
        Task {
            if let resolved = await SMBDiscovery.hostName(of: service) {
                address = resolved
            }
        }
    }

    private func connect() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let server = MediaServer(
            id: existing?.id ?? UUID(),
            kind: kind,
            name: trimmedName.isEmpty ? normalizedAddress : trimmedName,
            address: normalizedAddress,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        // Editing with the field left empty keeps the stored password.
        let newPassword = existing == nil || !password.isEmpty ? password : nil
        let effectivePassword = newPassword ?? existing.flatMap { ServerStore.login(for: $0.id)?.password } ?? ""
        isConnecting = true
        failure = nil
        Task {
            let problem = await Self.test(server, password: effectivePassword)
            isConnecting = false
            if let problem {
                failure = problem
            } else {
                if existing == nil {
                    ServerStore.shared.add(server, password: effectivePassword)
                } else {
                    ServerStore.shared.update(server, password: newPassword)
                }
                dismiss()
            }
        }
    }

    /// Lists the server's top level, which proves both that it is reachable and that the
    /// login works. Returns what went wrong, or nil.
    private nonisolated static func test(_ server: MediaServer, password: String) async -> String? {
        switch server.kind {
        case .smb:
            let credentials = SMBCredentials(host: server.address, username: server.username, password: password)
            return await Task.detached(priority: .userInitiated) { () -> String? in
                do throws(SMBError) {
                    _ = try SMBConnection(credentials).shares()
                    return nil
                } catch {
                    #if DEBUG
                    print("[smb] connecting failed: errno \(error.code)")
                    #endif
                    return error.localizedDescription
                }
            }.value
        case .webDAV:
            let client = WebDAVClient(baseURL: server.address, username: server.username, password: password)
            do {
                _ = try await client.contents(of: [])
                return nil
            } catch {
                return error.localizedDescription
            }
        }
    }
}
