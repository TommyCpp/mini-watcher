import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var service: MetricsService
    @EnvironmentObject var haService: HomeAssistantService
    @EnvironmentObject var tabSettings: TabSettings
    @State private var host: String = ""
    @State private var port: String = ""
    @State private var testResult: TestResult?
    @State private var isTesting = false
    @State private var haHost: String = ""
    @State private var haPort: String = ""
    @State private var haToken: String = ""
    @FocusState private var focusedField: Field?

    enum TestResult {
        case success, failure
    }

    enum Field {
        case host, port, haHost, haPort, haToken
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

                Section("Home Assistant") {
                    TextField("Host", text: $haHost)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($focusedField, equals: .haHost)

                    TextField("Port", text: $haPort)
                        .keyboardType(.numberPad)
                        .focused($focusedField, equals: .haPort)

                    SecureField("Access Token", text: $haToken)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($focusedField, equals: .haToken)
                }

                Section {
                    Button("Save & Connect HA") {
                        focusedField = nil
                        haService.haHost = haHost.trimmingCharacters(in: .whitespacesAndNewlines)
                        haService.haPort = haPort.trimmingCharacters(in: .whitespacesAndNewlines)
                        haService.haToken = haToken.trimmingCharacters(in: .whitespacesAndNewlines)
                        haService.startPolling()
                    }
                    .fontWeight(.medium)
                }

                Section("Tab Bar") {
                    NavigationLink("Customize Tabs") {
                        TabCustomizationView()
                    }
                }

                Section("Home Assistant Status") {
                    LabeledContent("Connected", value: haService.isConnected ? "Yes" : "No")
                    if let error = haService.errorMessage {
                        LabeledContent("Error", value: error)
                    }
                    LabeledContent("Sensors", value: "\(haService.rooms.count)")
                    ForEach(haService.rooms) { room in
                        LabeledContent(room.displayName, value: room.temperature.map { String(format: "%.1f%@", $0, room.temperatureUnit) } ?? "unavailable")
                    }
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
                haHost = haService.haHost
                haPort = haService.haPort
                haToken = haService.haToken
            }
        }
    }

    private func save() {
        service.serverHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        service.serverPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
