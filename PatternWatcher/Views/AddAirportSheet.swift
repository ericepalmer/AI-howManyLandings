import SwiftData
import SwiftUI

struct AddAirportSheet: View {
    let openICAOs: Set<String>
    var onOpen: (Airport) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var query = ""
    @State private var errorMessage: String?
    @FocusState private var queryFocused: Bool

    private var results: [Airport] {
        AirportCatalog.shared.search(query)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("ICAO, FAA ID, city, or name", text: $query)
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                        .autocorrectionDisabled()
                        .focused($queryFocused)
                        .onSubmit(addExact)
                }
                if !query.isEmpty {
                    Section("Matches") {
                        if results.isEmpty {
                            Text("No airport found for “\(query)”. Try an ICAO (KPAO), a local/FAA ID (CA35, 1C9), or the field name.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(results) { airport in
                            Button {
                                add(airport)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(airport.icao)
                                            .font(.headline.monospaced())
                                        if openICAOs.contains(airport.icao) {
                                            Text("Open")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Text(airport.displayName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .disabled(openICAOs.contains(airport.icao))
                        }
                    }
                } else {
                    Section {
                        Text("Private and small fields are included. Use the local identifier if there is no ICAO code. Pattern work is counted as individual landings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("New Airport")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open") { addExact() }
                        .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Could not open airport", isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .defaultFocus($queryFocused, true)
            .onAppear {
                queryFocused = true
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private func addExact() {
        let code = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        if let airport = AirportCatalog.shared.airport(code: code) ?? results.first {
            add(airport)
        } else {
            errorMessage = "No catalog match for \(code.uppercased()). Try an ICAO, FAA/local ID, or the airport name."
        }
    }

    private func add(_ airport: Airport) {
        guard !openICAOs.contains(airport.icao) else {
            dismiss()
            return
        }
        if !storedAirportExists(airport.icao) {
            modelContext.insert(StoredAirport(airport: airport))
            try? modelContext.save()
        }
        onOpen(airport)
        dismiss()
    }

    private func storedAirportExists(_ icao: String) -> Bool {
        let target = icao
        let descriptor = FetchDescriptor<StoredAirport>(
            predicate: #Predicate { $0.icao == target }
        )
        return (try? modelContext.fetch(descriptor).first) != nil
    }
}
