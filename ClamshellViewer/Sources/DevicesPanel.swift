import SwiftUI

// What the session screen shows about devices: the files being sent to the
// Mac, with progress, the result and Cancel, and each game controller with
// what the Mac does with it. Hidden when there is nothing to show.

struct DevicesPanel: View {
    @ObservedObject var files: FileSendController
    @ObservedObject var controllers: GameControllerBridge

    var body: some View {
        if !files.items.isEmpty || !controllers.rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if !files.items.isEmpty { transfers }
                if !controllers.rows.isEmpty { pads }
            }
            .font(.footnote)
            .foregroundStyle(.white)
            .padding(10)
            .frame(maxWidth: 360, alignment: .leading)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
            .padding(12)
        }
    }

    private var transfers: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Files to the Mac").font(.footnote.bold())
                Spacer()
                if files.busy {
                    Button("Cancel") { files.cancel() }
                } else {
                    Button("Clear") { files.clearFinished() }
                }
            }
            ForEach(files.items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    if let result = item.result {
                        Text(result).foregroundStyle(.white.opacity(0.7))
                    } else if item.size > 0 {
                        ProgressView(value: Double(item.sent), total: Double(item.size))
                            .tint(.white)
                    } else {
                        Text("Waiting").foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
        }
    }

    private var pads: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Game controllers").font(.footnote.bold())
            ForEach(controllers.rows, id: \.id) { row in
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.name).lineLimit(1)
                    Text(row.statusText).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
    }
}
