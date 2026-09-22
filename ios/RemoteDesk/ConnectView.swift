import SwiftUI

struct SessionTarget: Identifiable {
    let host: String
    let port: UInt16
    var id: String { "\(host):\(port)" }
}

struct ConnectView: View {
    @AppStorage("lastHost") private var lastHost = ""
    @AppStorage("pin") private var pin = ""
    @State private var hosts: [DiscoveredHost] = []
    @State private var searching = false
    @State private var session: SessionTarget?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if searching {
                        HStack {
                            ProgressView()
                            Text("検索中…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(hosts) { h in
                        Button {
                            lastHost = h.ip
                            session = SessionTarget(host: h.ip, port: h.port)
                        } label: {
                            HStack {
                                Image(systemName: "desktopcomputer")
                                VStack(alignment: .leading) {
                                    Text(h.name).foregroundStyle(.primary)
                                    Text("\(h.ip):\(String(h.port))").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                    }
                    if hosts.isEmpty && !searching {
                        Text("PC が見つかりません。PC 側で host.py を起動してから再検索してください。")
                            .foregroundStyle(.secondary)
                    }
                    Button { search() } label: {
                        Label("再検索", systemImage: "arrow.clockwise")
                    }
                    .disabled(searching)
                } header: {
                    Text("同じ Wi-Fi 内の PC")
                }

                Section("手動で接続") {
                    TextField("IP アドレス (例 192.168.1.10 または 192.168.1.10:47000)", text: $lastHost)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("PIN (host の config.json で設定した場合)", text: $pin)
                    Button {
                        let (h, p) = parse(lastHost)
                        session = SessionTarget(host: h, port: p)
                    } label: {
                        Label("接続", systemImage: "play.fill")
                    }
                    .disabled(lastHost.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Section("操作方法") {
                    Group {
                        Text("タップ: 左クリック / ドラッグ: 左ドラッグ")
                        Text("長押し または 2本指タップ: 右クリック")
                        Text("2本指ドラッグ: スクロール / ピンチ: 画面の拡大")
                        Text("3本指ドラッグ: 拡大中の表示移動 / 3本指タップ: ツールバー表示切替")
                        Text("2本指ダブルタップ: 拡大をリセット")
                        Text("ツールバーの手のアイコンでトラックパッドモードに切替")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("RemoteDesk")
        }
        .fullScreenCover(item: $session) { target in
            SessionView(host: target.host, port: target.port, pin: pin) {
                session = nil
            }
            .ignoresSafeArea()
            .persistentSystemOverlays(.hidden)
        }
        .onAppear { search() }
    }

    private func search() {
        searching = true
        Discovery.search { found in
            hosts = found
            searching = false
        }
    }

    private func parse(_ s: String) -> (String, UInt16) {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let idx = t.lastIndex(of: ":"), let p = UInt16(t[t.index(after: idx)...]) {
            return (String(t[..<idx]), p)
        }
        return (t, Proto.defaultPort)
    }
}
