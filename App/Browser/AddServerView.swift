import SwiftUI

/// Sheet for saving an SMB server: pick one found on the network or type an address,
/// then sign in. The server is saved only after a connection succeeds.
struct AddServerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var discovery = SMBDiscovery()
    @State private var host = ""
    @State private var name = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                if !discovery.services.isEmpty {
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
                    TextField("Address", text: $host, prompt: Text(verbatim: "nas.local"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Name", text: $name, prompt: Text("Optional"))
                } header: {
                    Text("Server")
                }
                Section {
                    TextField("Username", text: $username, prompt: Text("Guest"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } footer: {
                    if let failure {
                        Text(failure)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isConnecting {
                        ProgressView()
                    } else {
                        Button("Add") { connect() }
                            .disabled(trimmedHost.isEmpty)
                    }
                }
            }
            .disabled(isConnecting)
        }
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
    }

    private var trimmedHost: String {
        SMBServer.host(fromAddress: host)
    }

    private func select(_ service: SMBDiscovery.Service) {
        name = service.name
        Task {
            if let resolved = await SMBDiscovery.hostName(of: service) {
                host = resolved
            }
        }
    }

    private func connect() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let server = SMBServer(
            id: UUID(),
            name: trimmedName.isEmpty ? trimmedHost : trimmedName,
            host: trimmedHost,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let credentials = SMBCredentials(host: server.host, username: server.username, password: password)
        isConnecting = true
        failure = nil
        Task {
            // Listing the shares proves both that the server is reachable and that the login works.
            let result = await Task.detached(priority: .userInitiated) { () -> SMBError? in
                do throws(SMBError) {
                    _ = try SMBConnection(credentials).shares()
                    return nil
                } catch {
                    #if DEBUG
                    print("[smb] connecting failed: errno \(error.code)")
                    #endif
                    return error
                }
            }.value
            isConnecting = false
            if let result {
                failure = result.localizedDescription
            } else {
                ServerStore.shared.add(server, password: password)
                dismiss()
            }
        }
    }
}
