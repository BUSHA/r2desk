import SwiftUI
import R2Core

struct ConnectionView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let existing: Connection?
    @State private var name = ""
    @State private var accountID = ""
    @State private var jurisdiction = ""
    @State private var accessKey = ""
    @State private var secretKey = ""
    @State private var testing = false
    @State private var error: String?
    @State private var connectionTask: Task<Void, Never>?
    @FocusState private var focusedField: RequiredField?

    private enum RequiredField: String {
        case accountID = "Account ID"
        case accessKey = "Access key ID"
        case secretKey = "Secret access key"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                if let icon = AppIcon.image {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 44, height: 44)
                }
                Text(existing == nil ? "Connect your R2 account" : "Edit R2 connection").font(.title2.weight(.semibold))
            }
            Form {
                TextField("Connection name", text: $name, prompt: Text("My files"))
                TextField("Account ID", text: $accountID, prompt: Text("32-character Cloudflare account ID"))
                    .focused($focusedField, equals: .accountID)
                Picker("Storage location", selection: $jurisdiction) {
                    Text("Default").tag("")
                    Text("European Union (EU)").tag("eu")
                    Text("United States (US)").tag("us")
                    Text("FedRAMP").tag("fedramp")
                }
                Divider().padding(.vertical, 5)
                TextField("Access key ID", text: $accessKey)
                    .focused($focusedField, equals: .accessKey)
                SecureField("Secret access key", text: $secretKey)
                    .focused($focusedField, equals: .secretKey)
            }.textFieldStyle(.roundedBorder).disabled(testing)
            Link("Get R2 access keys", destination: URL(string: "https://developers.cloudflare.com/r2/api/tokens/")!).font(.caption)
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if testing { ProgressView().controlSize(.small); Text("Test connection…").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { connectionTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Connect" : "Save") { connect() }.keyboardShortcut(.defaultAction)
                    .disabled(testing)
            }
        }.padding(28).frame(width: 530)
        .interactiveDismissDisabled(testing)
        .onAppear {
            if let existing {
                name = existing.name; accountID = existing.accountID; jurisdiction = existing.jurisdiction
                do { let credentials = try Keychain.load(existing.id); accessKey = credentials.accessKey; secretKey = credentials.secretKey }
                catch { self.error = error.localizedDescription }
            }
        }
        .onDisappear { connectionTask?.cancel(); accessKey = ""; secretKey = "" }
    }
    private func connect() {
        guard !testing else { return }
        error = nil
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let requiredFields: [(RequiredField, String)] = [
            (.accountID, accountID), (.accessKey, accessKey), (.secretKey, secretKey)
        ]
        let missingFields = requiredFields.filter { trim($0.1).isEmpty }.map { $0.0 }
        if let firstMissingField = missingFields.first {
            error = "Enter " + ListFormatter.localizedString(byJoining: missingFields.map(\.rawValue)) + "."
            focusedField = firstMissingField
            return
        }
        let connection = Connection(id: existing?.id ?? UUID(), name: trim(name).isEmpty ? "R2 account" : trim(name),
                                    accountID: trim(accountID), jurisdiction: jurisdiction)
        let credentials = Credentials(accessKey: trim(accessKey), secretKey: trim(secretKey))
        do { try connection.validate() } catch { self.error = error.localizedDescription; return }
        testing = true
        connectionTask = Task { @MainActor in
            do {
                let client = S3Client(connection: connection, credentials: credentials)
                let buckets = try await client.listBuckets()
                try Task.checkCancellation()
                try model.saveConnection(connection, credentials: credentials, client: client, buckets: buckets)
                dismiss()
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            testing = false
        }
    }
}

struct TransfersView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Transfers").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if model.busy {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.status).font(.callout)
                    ProgressView(value: model.progress)
                    Button("Stop", action: model.cancel)
                }.padding(12).background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            if model.records.isEmpty {
                Spacer()
                Text("No transfers").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(model.records) { record in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: record.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(record.succeeded ? .green : .orange)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(record.title).font(.callout.weight(.medium))
                            Text(record.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(record.date, style: .time).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }.listStyle(.inset)
            }
        }.padding(24).frame(width: 570, height: 430)
    }
}
