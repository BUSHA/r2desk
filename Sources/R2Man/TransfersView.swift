import SwiftUI

struct TransfersView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transfers").font(.headline)
                Spacer()
                Button { model.showTransfers = false } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .padding(6).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Hide Transfers").accessibilityLabel("Hide Transfers")
            }.padding(16)
            Divider()
            if model.busy {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.status).font(.callout).fixedSize(horizontal: false, vertical: true)
                    ProgressView(value: model.progress)
                    Button("Stop", action: model.cancel).controlSize(.small)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                Divider()
            }
            if model.records.isEmpty {
                Text("No transfers").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.records) { record in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: record.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(record.succeeded ? .green : .orange)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(record.title).font(.callout.weight(.medium)).lineLimit(2)
                            Text(record.detail).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(record.date, style: .time).font(.caption2).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 6)
                }.listStyle(.inset)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
    }
}
