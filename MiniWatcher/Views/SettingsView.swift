import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var service: MetricsService
    @State private var host: String = ""
    @State private var port: String = ""
    @State private var testResult: TestResult?
    @State private var isTesting = false
    @FocusState private var focusedField: Field?

    enum TestResult {
        case success, failure
    }

    enum Field {
        case host, port
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server Connection") {
                    TextField("Host / IP Address", text: $host)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($focusedField, equals: .host)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .port }

                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                        .focused($focusedField, equals: .port)
                }

                Section {
                    Button {
                        focusedField = nil
                        save()
                        isTesting = true
                        testResult = nil
                        Task {
                            let ok = await service.testConnection()
                            testResult = ok ? .success : .failure
                            isTesting = false
                        }
                    } label: {
                        HStack {
                            Text("Test Connection")
                            Spacer()
                            if isTesting {
                                ProgressView()
                            } else if let result = testResult {
                                Image(systemName: result == .success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(result == .success ? .green : .red)
                            }
                        }
                    }
                }

                Section {
                    Button("Save & Reconnect") {
                        focusedField = nil
                        save()
                        service.startPolling()
                    }
                    .fontWeight(.medium)
                }

                Section("Status") {
                    LabeledContent("Connected", value: service.isConnected ? "Yes" : "No")
                    if let error = service.errorMessage {
                        LabeledContent("Error", value: error)
                    }
                    LabeledContent("URL", value: service.baseURL)
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                host = service.serverHost
                port = service.serverPort
            }
        }
    }

    private func save() {
        service.serverHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        service.serverPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
