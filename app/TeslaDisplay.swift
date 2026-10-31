// Tesla Display: desktop app สำหรับเลือกจอ แล้วส่งภาพ (mac-capture | ffmpeg -> WHIP)
// และรับ touch/keyboard จาก Tesla (mac-input-agent)
// build: ./scripts/build-app.sh
import AppKit
import CoreGraphics
import SwiftUI

struct DisplayInfo: Identifiable, Hashable {
    let index: Int
    let name: String
    let size: String
    var id: Int { index }
}

func listDisplays() -> [DisplayInfo] {
    var names: [CGDirectDisplayID: String] = [:]
    for s in NSScreen.screens {
        if let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            names[id] = s.localizedName
        }
    }
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return ids.enumerated().map { i, d in
        let b = CGDisplayBounds(d)
        return DisplayInfo(index: i, name: names[d] ?? "Display \(d)", size: "\(Int(b.width))x\(Int(b.height))")
    }
}

struct PublishSettings {
    var url: String
    var token: String
    var display: Int
    var size: String
    var fps: Int
    var bitrate: Int
    var control: Bool
    var extend: Bool // true = สร้างจอเสมือนให้ Tesla เป็นจอที่ 2, false = mirror จอที่เลือก
    var local: Bool  // true = Mac เป็น server เอง (Tesla ต่อตรงผ่าน Wi-Fi/hotspot ไม่ใช้ server ข้างนอก)
    var pin: String  // โหมด local: PIN ที่ Tesla ต้องใส่เพื่อดู/ควบคุม
    var audio = true         // ส่งเสียงระบบไปพร้อมภาพ (Opus)
    var virtualSize = "auto" // Extend: ขนาดจอเสมือน (= พื้นที่ทำงาน) หรือ "auto" = ตามจอ Tesla ที่เปิดหน้าเว็บ
}

// IPv4 ของ Mac ทุก interface (ไว้แสดง URL ให้พิมพ์บน Tesla) — Internet Sharing (192.168.2.x) ขึ้นก่อน
func localIPv4s() -> [(name: String, ip: String)] {
    var result: [(String, String)] = []
    var ifap: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
    defer { freeifaddrs(ifap) }
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let ifa = ptr.pointee
        guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
              (ifa.ifa_flags & UInt32(IFF_UP)) != 0, (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        result.append((String(cString: ifa.ifa_name), String(cString: host)))
    }
    return result.sorted { a, _ in a.1.hasPrefix("192.168.2.") }
}

@MainActor
final class Controller: ObservableObject {
    static let shared = Controller()

    @Published var displays: [DisplayInfo] = listDisplays()
    @Published var running = false
    @Published var status = "Stopped"
    @Published var log: [String] = []
    @Published var startedAt: Date? // เวลาที่กด Start (ไว้แสดงเวลาที่รันไปแล้ว)
    @Published var teslaScreen: String? // ขนาดจอที่ Tesla รายงานมา เช่น "1920x1200 @1x"
    @Published var sendStats: String?   // ที่ ffmpeg กำลังส่งจริง เช่น "60 fps · 7.8 Mbps" (จาก -progress ทุก 1 วินาที)
    private var autoSize = false
    private var virtualSizeNow = (w: 0, h: 0)

    private var capture: Process?
    private var localServer: Process?
    private var localWeb: Process?
    static let localHTTPS = 8443
    static let localHTTP = 8080
    private let localWHIP = "http://127.0.0.1:8889/screen/whip"
    private var ffmpeg: Process?
    private var agent: Process?
    private var settings: PublishSettings?
    private var virtualDisplay: CGVirtualDisplay?
    private var permissionDenied = false
    private let resources = Bundle.main.resourceURL!

    func refresh() { displays = listDisplays() }

    func start(_ s: PublishSettings) {
        guard !running else { return }
        guard let ffmpegPath = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: FileManager.default.isExecutableFile) else {
            status = "ffmpeg not found (brew install ffmpeg)"
            return
        }
        if s.local {
            guard s.pin.count >= 4 else {
                status = "PIN must be at least 4 characters"
                return
            }
        } else {
            guard !s.token.isEmpty, URL(string: s.url)?.host != nil else {
                status = "Enter Server URL and Token first"
                return
            }
        }
        running = true
        startedAt = Date()
        guard s.extend else { return launch(s, ffmpegPath: ffmpegPath) }

        autoSize = s.virtualSize == "auto"
        // Auto: เริ่มที่ 1920x1200 ก่อน แล้วปรับตามจอ Tesla เมื่อหน้าเว็บรายงานขนาดมา
        let parts = (autoSize ? "1920x1200" : s.virtualSize).split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, let id = createVirtualDisplay(width: parts[0], height: parts[1]) else {
            status = "Could not create virtual display (try Mirror mode)"
            running = false
            return
        }
        status = "Creating virtual display…"
        waitForDisplay(id, attempts: 25) { [weak self] index in
            guard let self, self.running else { return }
            guard let index else {
                self.status = "Virtual display did not appear (try Mirror mode)"
                self.stop()
                return
            }
            self.setNativeMode(id, width: parts[0])
            var s = s
            s.display = index
            // รอ mode ใหม่มีผลก่อนเริ่มจับภาพ
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.running else { return }
                self.launch(s, ffmpegPath: ffmpegPath)
            }
        }
    }

    private func launch(_ s: PublishSettings, ffmpegPath: String) {
        refresh()
        settings = s
        permissionDenied = false
        if s.local {
            guard startLocalServer(), startLocalWeb(pin: s.pin) else { return stop() }
        }
        // โหมด local ต้องมี agent เสมอ เพราะเป็นตัวตรวจ PIN ให้หน้าเว็บบน Mac
        if s.control || s.local { startAgent(s) }
        // ให้ mediamtx บน Mac พร้อมก่อน ffmpeg ส่งภาพเข้า
        DispatchQueue.main.asyncAfter(deadline: .now() + (s.local ? 0.8 : 0)) { [weak self] in
            guard let self, self.running else { return }
            self.startPublish(s, ffmpegPath: ffmpegPath)
        }
    }

    // จอเสมือนจะอยู่ตราบที่ object นี้ยังอยู่ (stop() ปล่อยทิ้ง -> จอหายไป)
    private func createVirtualDisplay(width: Int, height: Int) -> CGDirectDisplayID? {
        let desc = CGVirtualDisplayDescriptor()
        desc.queue = DispatchQueue.main
        desc.name = "Tesla Display"
        // เผื่อขนาดสูงสุดไว้ เพื่อให้ Auto ปรับขนาดภายหลังได้โดยไม่ต้องสร้างจอใหม่
        desc.maxPixelsWide = UInt32(max(width, 3840))
        desc.maxPixelsHigh = UInt32(max(height, 2400))
        // ขนาดจริงสมมติที่ ~96 ppi (1x) ไม่งั้น macOS ถือเป็นจอความละเอียดสูง
        desc.sizeInMillimeters = CGSize(width: Double(width) / 96 * 25.4, height: Double(height) / 96 * 25.4)
        desc.vendorID = 0x7E51
        desc.productID = 0x0001
        desc.serialNum = 1 // คงที่ -> macOS จำตำแหน่งจอที่จัดไว้ใน Displays settings
        desc.terminationHandler = { _, _ in }
        guard let display = CGVirtualDisplay(descriptor: desc) else { return nil }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 0
        settings.modes = [CGVirtualDisplayMode(width: UInt(width), height: UInt(height), refreshRate: 60)]
        guard display.apply(settings) else { return nil }
        virtualDisplay = display
        virtualSizeNow = (width, height)
        return display.displayID
    }

    // หน้าเว็บบน Tesla รายงานขนาดจอ (CSS px) -> Auto: ปรับจอเสมือนให้เท่านั้น แล้วเริ่มจับภาพใหม่
    private func viewerScreen(width: Int, height: Int, dpr: Double) {
        teslaScreen = "\(width)x\(height) @\(dpr == dpr.rounded() ? String(Int(dpr)) : String(format: "%.2f", dpr))x"
        guard running, autoSize, let display = virtualDisplay else { return }
        let w = min(max(width, 1024), 3840) / 2 * 2, h = min(max(height, 600), 2400) / 2 * 2
        guard (w, h) != virtualSizeNow else { return }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 0
        settings.modes = [CGVirtualDisplayMode(width: UInt(w), height: UInt(h), refreshRate: 60)]
        guard display.apply(settings) else {
            append("auto: resize to \(w)x\(h) failed")
            return
        }
        virtualSizeNow = (w, h)
        append("auto: virtual display -> \(w)x\(h) (Tesla \(teslaScreen ?? ""))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.running else { return }
            self.setNativeMode(display.displayID, width: w)
            // ปิดตัวจับภาพ -> ffmpeg จบ -> publishExited เริ่มใหม่ด้วยขนาดใหม่ (Tesla ต่อใหม่เอง)
            self.capture?.terminate()
        }
    }

    // macOS เริ่มจอเสมือนที่ mode เล็ก (เช่น 960x600) -> บังคับเป็นความละเอียดเต็มแบบ 1x
    private func setNativeMode(_ id: CGDirectDisplayID, width: Int) {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
        guard let mode = modes.first(where: { $0.width == width && $0.pixelWidth == width }) else { return }
        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        CGConfigureDisplayWithDisplayMode(config, id, mode, nil)
        CGCompleteDisplayConfiguration(config, .forSession)
    }

    private func waitForDisplay(_ id: CGDirectDisplayID, attempts: Int, then: @escaping (Int?) -> Void) {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        if let index = ids.firstIndex(of: id) { return then(index) }
        guard attempts > 0 else { return then(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.waitForDisplay(id, attempts: attempts - 1, then: then)
        }
    }

    func stop() {
        running = false
        startedAt = nil
        teslaScreen = nil
        sendStats = nil
        settings = nil
        for p in [capture, ffmpeg, agent, localServer, localWeb] where p?.isRunning == true { p?.terminate() }
        localServer = nil
        localWeb = nil
        capture = nil
        ffmpeg = nil
        agent = nil
        virtualDisplay = nil
        status = "Stopped"
        refresh()
    }

    private func startPublish(_ s: PublishSettings, ffmpegPath: String) {
        let capPath = resources.appendingPathComponent("mac-capture").path
        let (w, h) = fit(capPath: capPath, display: s.display, box: s.size)
        let whip = s.local ? localWHIP : s.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/screen/whip"

        let cap = Process()
        cap.executableURL = URL(fileURLWithPath: capPath)
        cap.arguments = ["stream", "\(s.display)", "\(w)", "\(h)", "\(s.fps)"]
        // เสียง: mac-capture เขียน PCM ลง FIFO แยก แล้ว ffmpeg อ่านเป็น input ที่ 2
        var audioArgs: [String] = []
        var audioMap: [String] = []
        if s.audio, let fifo = makeAudioFIFO() {
            cap.arguments!.append(fifo)
            audioArgs = ["-f", "f32le", "-ar", "48000", "-ac", "2", "-thread_queue_size", "1024", "-i", fifo]
            audioMap = ["-map", "0:v", "-map", "1:a", "-c:a", "libopus", "-b:a", "128k", "-ar", "48000"]
        }

        let ff = Process()
        ff.executableURL = URL(fileURLWithPath: ffmpegPath)
        ff.arguments = [
            "-hide_banner", "-loglevel", "warning",
            "-nostats", "-progress", "pipe:1", "-stats_period", "1",
            "-f", "rawvideo", "-pix_fmt", "nv12", "-color_range", "tv", "-video_size", "\(w)x\(h)", "-framerate", "\(s.fps)",
            "-thread_queue_size", "64", "-i", "-",
        ] + audioArgs + audioMap + [
            // libx264 zerolatency: POC type 2 (ไม่มีการสลับลำดับเฟรม) — h264_videotoolbox ใช้ POC type 0
            // ซึ่งพอมี packet loss แล้ว mediamtx เข้าใจผิดว่ามี B-frames แล้วตัดคนดู
            // bufsize ครึ่งวินาที = จำกัดขนาดเฟรม (keyframe) ไม่ให้ระเบิดเป็นก้อนจน UDP หาย
            "-c:v", "libx264", "-preset", s.fps > 30 ? "superfast" : "veryfast", "-tune", "zerolatency",
            "-profile:v", "main", "-bf", "0", "-g", "\(s.fps)",
            "-b:v", "\(s.bitrate)M", "-maxrate", "\(s.bitrate)M", "-bufsize", "\(max(1, s.bitrate / 2))M",
            "-f", "whip", "-authorization", s.token, whip,
        ]

        let pipe = Pipe()
        cap.standardOutput = pipe
        ff.standardInput = pipe
        cap.standardError = logPipe("capture")
        ff.standardError = logPipe("ffmpeg")
        ff.standardOutput = progressPipe()

        ff.terminationHandler = { [weak self] p in
            Task { @MainActor in self?.publishExited(code: p.terminationStatus) }
        }
        cap.terminationHandler = { p in
            if ff.isRunning { ff.terminate() }
        }

        do {
            try cap.run()
            try ff.run()
            capture = cap
            ffmpeg = ff
            status = "Live\(s.local ? " (local)" : ""): \(displays.first { $0.index == s.display }?.name ?? "display \(s.display)") \(w)x\(h)"
        } catch {
            status = "start failed: \(error.localizedDescription)"
            stop()
        }
    }

    // ffmpeg ออกเอง (เน็ตหลุด / server restart) -> ลองใหม่ทุก 3 วินาทีจนกว่าจะกด Stop
    // ffmpeg -progress: บรรทัด key=value ทุก 1 วินาที จบชุดด้วย progress=continue
    // fps/bitrate ของ ffmpeg เป็นค่าเฉลี่ยตั้งแต่เริ่ม -> คำนวณ realtime จาก frame / total_size ที่เพิ่มขึ้นแต่ละชุดแทน
    private func progressPipe() -> Pipe {
        let pipe = Pipe()
        // readabilityHandler ของ handle เดียวถูกเรียกทีละครั้ง จึงเก็บค่าชุดก่อนหน้าไว้ใน box ได้
        final class Current: @unchecked Sendable {
            var frame = 0, size = 0
            var prevFrame = -1, prevSize = 0, prevTime = Date()
        }
        let cur = Current()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let text = String(decoding: h.availableData, as: UTF8.self)
            for line in text.split(whereSeparator: \.isNewline) {
                let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
                guard kv.count == 2 else { continue }
                switch kv[0] {
                case "frame": cur.frame = Int(kv[1]) ?? cur.frame
                case "total_size": cur.size = Int(kv[1]) ?? cur.size
                case "progress":
                    let now = Date()
                    defer { cur.prevFrame = cur.frame; cur.prevSize = cur.size; cur.prevTime = now }
                    let dt = now.timeIntervalSince(cur.prevTime)
                    guard cur.prevFrame >= 0, dt > 0.2 else { continue }
                    let fps = Double(cur.frame - cur.prevFrame) / dt
                    let mbps = Double(cur.size - cur.prevSize) * 8 / dt / 1_000_000
                    // บาง muxer (เช่น whip) อาจไม่รายงาน total_size -> แสดงแค่ fps
                    let text = cur.size > 0 ? String(format: "%.0f fps · %.1f Mbps", fps, max(0, mbps))
                                            : String(format: "%.0f fps", fps)
                    Task { @MainActor in if self?.running == true { self?.sendStats = text } }
                default: break
                }
            }
        }
        return pipe
    }

    private func publishExited(code: Int32) {
        guard running, let s = settings else { return }
        if capture?.isRunning == true { capture?.terminate() }
        status = "Disconnected (exit \(code)) — retrying…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.running, let ffmpegPath = self.ffmpeg?.executableURL?.path else { return }
            // ไม่มีสิทธิ์จับภาพ -> ลองใหม่ก็ไม่ผ่าน และ macOS จะเด้งถามซ้ำ จึงหยุดเลย
            if self.permissionDenied {
                self.stop()
                self.status = "No Screen Recording permission: allow Tesla Display, then quit and reopen the app"
                return
            }
            self.startPublish(s, ffmpegPath: ffmpegPath)
        }
    }

    private var supportDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tesla Display", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // ใบรับรอง self-signed สร้างครั้งเดียวแล้วใช้ซ้ำ (Tesla กดยอมรับครั้งเดียว)
    private func ensureCertificate() -> (cert: String, key: String)? {
        let cert = supportDir.appendingPathComponent("local-cert.pem").path
        let key = supportDir.appendingPathComponent("local-key.pem").path
        if FileManager.default.fileExists(atPath: cert), FileManager.default.fileExists(atPath: key) { return (cert, key) }
        let san = (["192.168.2.1", "172.20.10.1"] + localIPv4s().map(\.ip)).map { "IP:\($0)" } + ["DNS:localhost"]
        let conf = supportDir.appendingPathComponent("openssl.cnf")
        let cnf = """
        [req]
        distinguished_name = dn
        x509_extensions = ext
        prompt = no
        [dn]
        CN = Tesla Display (local)
        [ext]
        subjectAltName = \(Set(san).sorted().joined(separator: ","))
        basicConstraints = CA:FALSE
        keyUsage = digitalSignature, keyEncipherment
        extendedKeyUsage = serverAuth

        """
        try? cnf.write(to: conf, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3650",
                       "-config", conf.path, "-keyout", key, "-out", cert]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = logPipe("cert")
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        return p.terminationStatus == 0 ? (cert, key) : nil
    }

    // Caddy บน Mac: เสิร์ฟหน้าเว็บให้ Tesla ทั้ง https:8443 (self-signed) และ http:8080
    //   /screen/whep -> mediamtx (ต้องมี PIN), /screen/whip ปิดจากภายนอก, /input -> agent
    private func startLocalWeb(pin: String) -> Bool {
        guard let tls = ensureCertificate() else {
            status = "Could not create certificate"
            return false
        }
        let web = resources.appendingPathComponent("web").path
        let caddyfile = supportDir.appendingPathComponent("Caddyfile")
        let conf = """
        {
        \tadmin off
        \tauto_https off
        \tpersist_config off
        }

        (site) {
        \thandle /screen/whip* {
        \t\trespond 403
        \t}
        \thandle /screen/* {
        \t\t@nopin not header Authorization "Bearer \(pin)"
        \t\trespond @nopin 401
        \t\treverse_proxy 127.0.0.1:8889
        \t}
        \thandle /input/* {
        \t\treverse_proxy 127.0.0.1:8766
        \t}
        \thandle {
        \t\theader Cache-Control no-store
        \t\troot * "\(web)"
        \t\ttry_files {path} /index.html
        \t\tfile_server
        \t}
        }

        https://:\(Controller.localHTTPS) {
        \ttls "\(tls.cert)" "\(tls.key)"
        \timport site
        }

        http://:\(Controller.localHTTP) {
        \timport site
        }

        """
        do {
            try conf.write(to: caddyfile, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = resources.appendingPathComponent("caddy")
            p.arguments = ["run", "--config", caddyfile.path, "--adapter", "caddyfile"]
            p.environment = ["HOME": supportDir.path, "XDG_DATA_HOME": supportDir.path, "XDG_CONFIG_HOME": supportDir.path]
            p.standardOutput = logPipe("web")
            p.standardError = logPipe("web")
            try p.run()
            localWeb = p
            return true
        } catch {
            status = "start local web failed: \(error.localizedDescription)"
            return false
        }
    }

    // mediamtx บน Mac สำหรับโหมด local: HTTP ฟังเฉพาะ 127.0.0.1 (ffmpeg + agent เท่านั้น)
    // ส่วน UDP 8189 เปิดทุก interface ให้ Tesla ในวง hotspot ต่อเข้ามาตรง
    private func startLocalServer() -> Bool {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tesla Display", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = dir.appendingPathComponent("mediamtx-local.yml")
        let yaml = """
        logLevel: info
        api: no
        rtsp: no
        rtmp: no
        hls: no
        srt: no
        webrtc: yes
        webrtcAddress: 127.0.0.1:8889
        webrtcLocalUDPAddress: :8189
        webrtcLocalTCPAddress: ""
        webrtcIPsFromInterfaces: yes
        webrtcAdditionalHosts: []
        webrtcICEServers2: []
        authMethod: internal
        authInternalUsers:
          - user: any
            pass:
            permissions:
              - action: publish
                path: screen
              - action: read
                path: screen
        paths:
          screen:

        """
        do {
            try yaml.write(to: config, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = resources.appendingPathComponent("mediamtx")
            p.arguments = [config.path]
            p.standardOutput = logPipe("local")
            p.standardError = logPipe("local")
            try p.run()
            localServer = p
            return true
        } catch {
            status = "start local server failed: \(error.localizedDescription)"
            return false
        }
    }

    private func startAgent(_ s: PublishSettings) {
        let p = Process()
        p.executableURL = resources.appendingPathComponent("mac-input-agent")
        p.arguments = ["\(s.display)"]
        p.environment = s.local
            ? ["LOCAL_LISTEN": "8766", "LOCAL_PIN": s.pin, "CONTROL": s.control ? "1" : "0"]
            : ["SCREEN_URL": s.url, "TOKEN": s.token, "CONTROL": s.control ? "1" : "0"]
        p.standardOutput = logPipe("input")
        p.standardError = logPipe("input")
        do {
            try p.run()
            agent = p
        } catch {
            append("input: \(error.localizedDescription)")
        }
    }

    private func makeAudioFIFO() -> String? {
        let path = supportDir.appendingPathComponent("audio.fifo").path
        unlink(path)
        return mkfifo(path, 0o600) == 0 ? path : nil
    }

    private func fit(capPath: String, display: Int, box: String) -> (Int, Int) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: capPath)
        p.arguments = ["size", "\(display)", box]
        let out = Pipe()
        p.standardOutput = out
        try? p.run()
        p.waitUntilExit()
        let parts = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: " ").compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return parts.count == 2 ? (parts[0], parts[1]) : (1920, 1080)
    }

    private func logPipe(_ tag: String) -> Pipe {
        let pipe = Pipe()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let text = String(decoding: h.availableData, as: UTF8.self)
            guard !text.isEmpty else { return }
            Task { @MainActor in
                for line in text.split(whereSeparator: \.isNewline) {
                    if tag == "capture", line.contains("cannot access screen") || line.contains("declined TCC") {
                        self?.permissionDenied = true
                    }
                    if tag == "input", line.hasPrefix("viewer-screen ") {
                        let f = line.split(separator: " ")
                        if f.count == 4, let w = Int(f[1]), let h = Int(f[2]), let d = Double(f[3]) {
                            self?.viewerScreen(width: w, height: h, dpr: d)
                        }
                    }
                    self?.append("\(tag): \(line)")
                }
            }
        }
        return pipe
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}

let teslaRed = Color(red: 0.89, green: 0.12, blue: 0.16)

// การ์ดพื้นโปร่งแสงสำหรับจัดกลุ่มการตั้งค่า
struct Card<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(teslaRed)
                Text(title.uppercased()).tracking(1.4)
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(.white.opacity(0.65))
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.03)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }
}

// จุดสถานะ: เต้นเป็นจังหวะเมื่อกำลังส่งภาพ
struct PulseDot: View {
    let color: Color
    let active: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            if active {
                Circle().fill(color.opacity(0.45)).frame(width: 18, height: 18)
                    .scaleEffect(pulse ? 1.25 : 0.6).opacity(pulse ? 0 : 0.9)
            }
            Circle().fill(color).frame(width: 9, height: 9).shadow(color: color, radius: active ? 5 : 0)
        }
        .frame(width: 18, height: 18)
        .onAppear { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true } }
    }
}

// ปุ่มหลัก: แคปซูลไล่สีแดงมีแสงเรือง / ปุ่มรอง: แคปซูลมืดขอบแดง
struct GlowButton: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 11)
            .background {
                if primary {
                    Capsule().fill(LinearGradient(colors: [Color(red: 1, green: 0.3, blue: 0.3), Color(red: 0.75, green: 0.06, blue: 0.1)],
                                                  startPoint: .top, endPoint: .bottom))
                } else {
                    Capsule().fill(.white.opacity(0.08))
                }
            }
            .overlay(Capsule().strokeBorder(primary ? .white.opacity(0.25) : teslaRed.opacity(0.7)))
            .shadow(color: primary ? teslaRed.opacity(configuration.isPressed ? 0.3 : 0.6) : .clear, radius: 12, y: 3)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct ContentView: View {
    @EnvironmentObject var c: Controller
    @AppStorage("serverURL") private var serverURL = "https://screen.example.com"
    @AppStorage("token") private var token = ""
    @AppStorage("displayName") private var displayName = ""
    @AppStorage("size") private var size = "1920x1200"
    @AppStorage("fps") private var fps = 30
    @AppStorage("bitrate") private var bitrate = 8
    @AppStorage("control") private var control = true
    @AppStorage("audio") private var audio = true
    @AppStorage("showStats") private var showStats = false  // แสดง fps / bitrate ที่กำลังส่ง (ปิดเป็นค่าเริ่มต้น)
    @AppStorage("extend") private var extend = true
    @AppStorage("resolution") private var virtualSize = "auto"
    @AppStorage("local") private var local = false
    @AppStorage("localPin") private var localPin = ""
    @State private var ips: [(name: String, ip: String)] = []
    @State private var copied = ""
    @State private var display = 0
    @State private var showLog = false
    @State private var showToken = false

    private var statusColor: Color {
        guard c.running else { return .gray }
        return c.status.hasPrefix("Live") ? .green : .orange
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
        VStack(alignment: .leading, spacing: 14) {
            header

            Card(title: "Display", icon: "display") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        label("Mode")
                        Picker("", selection: $extend) {
                            Text("Extend").tag(true)
                            Text("Mirror").tag(false)
                        }.labelsHidden().pickerStyle(.segmented).fixedSize()
                    }
                    Group {
                        if extend {
                            GridRow {
                                label("Resolution")
                                Picker("", selection: $virtualSize) {
                                    Text("Auto (match Tesla screen)").tag("auto")
                                    Section("More workspace (smaller text)") {
                                        Text("3840x2400").tag("3840x2400")
                                        Text("3360x2100").tag("3360x2100")
                                        Text("2880x1800").tag("2880x1800")
                                        Text("2560x1600").tag("2560x1600")
                                        Text("2304x1440").tag("2304x1440")
                                    }
                                    Section("Fits car screen") {
                                        Text("1920x1200").tag("1920x1200")
                                    }
                                    Section("Larger text") {
                                        Text("1680x1050").tag("1680x1050")
                                        Text("1440x900").tag("1440x900")
                                        Text("1280x800 (slow network)").tag("1280x800")
                                    }
                                }.labelsHidden().fixedSize()
                            }
                            GridRow {
                                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                                Text(c.teslaScreen.map { "Tesla screen: \($0)" + (virtualSize == "auto" ? " · adjusted" : "") }
                                 ?? (virtualSize == "auto" ? "Auto: resizes when Tesla opens the page" : "Tesla is your Mac's 2nd display · drag windows onto it"))
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            GridRow {
                                label("Screen")
                                Picker("", selection: $display) {
                                    ForEach(c.displays) { d in Text("\(d.name) — \(d.size)").tag(d.index) }
                                }.labelsHidden()
                            }
                            GridRow {
                                label("Size")
                                Picker("", selection: $size) {
                                    Text("1920x1200 (Tesla)").tag("1920x1200")
                                    Text("2560x1600").tag("2560x1600")
                                    Text("1280x800 (slow network)").tag("1280x800")
                                    Text("Native").tag("")
                                }.labelsHidden().fixedSize()
                            }
                        }
                        GridRow {
                            label("FPS")
                            Picker("", selection: $fps) {
                                Text("30").tag(30)
                                Text("60").tag(60)
                            }.labelsHidden().pickerStyle(.segmented).fixedSize()
                        }
                        GridRow {
                            label("Bitrate")
                            Stepper("\(bitrate) Mbps", value: $bitrate, in: 2...20).monospacedDigit()
                        }
                    }
                    .disabled(c.running) // สลับ Mode ได้ระหว่างส่งภาพ ส่วนค่าอื่นต้อง Stop ก่อน
                }
            }

            Card(title: "Connection", icon: "network") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        label("Route")
                        Picker("", selection: $local) {
                            Text("Home Server").tag(false)
                            Text("Direct Wi-Fi").tag(true)
                        }.labelsHidden().pickerStyle(.segmented).fixedSize()
                    }
                    if local {
                        GridRow {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                            Text("Your Mac is the server — no outside server\nTesla joins the Mac's Wi-Fi, then enters the PIN")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        GridRow {
                            label("PIN")
                            HStack(spacing: 6) {
                                TextField("PIN", text: $localPin)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                                    .frame(width: 140)
                                    .onChange(of: localPin) { localPin = String(localPin.filter { $0.isLetter || $0.isNumber }.prefix(16)) }
                                Button { copy(localPin) } label: { copyIcon(localPin) }
                                    .buttonStyle(.borderless).help("Copy PIN")
                                Button { localPin = randomPin() } label: { Image(systemName: "dice") }
                                    .buttonStyle(.borderless).help("Generate new PIN")
                            }
                        }
                    } else {
                        GridRow {
                            label("Server")
                            TextField("https://screen.example.com", text: $serverURL).textFieldStyle(.roundedBorder)
                                .frame(maxWidth: .infinity)
                        }
                        GridRow {
                            label("Token")
                            HStack(spacing: 6) {
                                Group {
                                    if showToken {
                                        TextField("PUBLISH_TOKEN", text: $token).font(.system(.body, design: .monospaced))
                                    } else {
                                        SecureField("PUBLISH_TOKEN", text: $token)
                                    }
                                }.textFieldStyle(.roundedBorder)
                                Button { showToken.toggle() } label: {
                                    Image(systemName: showToken ? "eye.slash" : "eye")
                                }
                                .buttonStyle(.borderless)
                                .help(showToken ? "Hide token" : "Show token")
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Touch / keyboard / gamepad control from Tesla", isOn: $control).fixedSize()
                            Toggle("Send Mac audio to Tesla", isOn: $audio).fixedSize()
                        }
                    }
                }
            }
            .disabled(c.running)

            if local { teslaURLs }

            HStack(spacing: 10) {
                PulseDot(color: statusColor, active: c.running)
                Text(c.status).font(.callout.weight(.medium)).foregroundStyle(.white.opacity(0.8)).lineLimit(2)
                if showStats, c.running, let stats = c.sendStats {
                    Spacer(minLength: 8)
                    Text(stats)
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(statusColor)
                        .help("FPS / bitrate ที่ Mac กำลังส่ง (อัปเดตทุก 1 วินาที)")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(statusColor.opacity(c.running ? 0.12 : 0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(statusColor.opacity(c.running ? 0.35 : 0.15)))

            HStack {
                if c.running {
                    Button { c.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(GlowButton(primary: false))
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button { startStreaming() } label: { Label("Start", systemImage: "play.fill") }
                        .buttonStyle(GlowButton(primary: true))
                        .keyboardShortcut(.defaultAction)
                }
                Spacer()
                Toggle(isOn: $showStats) { Image(systemName: "chart.bar.xaxis") }
                    .toggleStyle(.button)
                    .help(showStats ? "Hide live FPS / bitrate" : "Show live FPS / bitrate")
                Toggle(isOn: $showLog.animation(.spring(response: 0.35, dampingFraction: 0.85))) {
                    Label("Log", systemImage: showLog ? "sidebar.right" : "text.alignleft")
                }.toggleStyle(.button)
                Button("Quit") { c.stop(); NSApp.terminate(nil) }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 2)
        .padding(.bottom, 18)
        .frame(width: 460)

            if showLog {
                logPanel
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background {
            ZStack {
                LinearGradient(colors: [Color(red: 0.09, green: 0.09, blue: 0.11), Color(red: 0.02, green: 0.02, blue: 0.03)],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [teslaRed.opacity(0.35), .clear], center: .topTrailing, startRadius: 10, endRadius: 420)
                RadialGradient(colors: [Color(red: 0.2, green: 0.3, blue: 0.9).opacity(0.12), .clear], center: .bottomLeading, startRadius: 10, endRadius: 380)
            }
            .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
        .onChange(of: extend) {
            // สลับ Extend/Mirror ระหว่างส่งภาพ -> หยุดแล้วเริ่มใหม่ด้วยโหมดใหม่
            guard c.running else { return }
            c.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { startStreaming() }
        }
        .onAppear {
            c.refresh()
            ips = localIPv4s()
            if localPin.isEmpty { localPin = randomPin() }
            // จำจอจากชื่อ (เลขจออาจเปลี่ยนเมื่อเสียบ/ถอดจอ)
            if let d = c.displays.first(where: { $0.name == displayName }) { display = d.index }
        }
    }

    private func startStreaming() {
        if !extend { displayName = c.displays.first { $0.index == display }?.name ?? "" }
        c.start(PublishSettings(url: serverURL, token: token, display: display,
                                // Extend: ภาพที่ส่งไม่เกินจอรถ (1920x1200) แม้จอเสมือนจะใหญ่กว่า
                                size: extend ? "1920x1200" : size,
                                fps: fps, bitrate: bitrate, control: control, extend: extend, local: local,
                                pin: localPin, audio: audio, virtualSize: virtualSize))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "car.side.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(LinearGradient(colors: [Color(red: 1, green: 0.27, blue: 0.27), Color(red: 0.55, green: 0.04, blue: 0.08)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.white.opacity(0.25)))
                .shadow(color: teslaRed.opacity(c.running ? 0.8 : 0.45), radius: c.running ? 16 : 10)
            VStack(alignment: .leading, spacing: 3) {
                Text("Tesla Display")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [.white, .white.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                Text("Your Mac, on the big screen in your car")
                    .font(.caption).foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            if let start = c.startedAt { uptime(since: start) }
            Button { c.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Refresh displays").disabled(c.running)
        }
    }

    // เวลาที่รันไปแล้ว (มุมขวาบน) อัปเดตทุกวินาที
    private func uptime(since start: Date) -> some View {
        TimelineView(.periodic(from: start, by: 1)) { ctx in
            let t = max(0, Int(ctx.date.timeIntervalSince(start)))
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(String(format: "%02d:%02d:%02d", t / 3600, t / 60 % 60, t % 60))
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.white.opacity(0.08), in: Capsule())
            .help("Running time")
        }
    }

    // แผง Log ที่เลื่อนออกทางขวา (สูงเท่าหน้าต่าง, เลื่อนลงล่างสุดอัตโนมัติ)
    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "text.alignleft").foregroundStyle(teslaRed)
                Text("LOG").tracking(1.4).font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.65))
                Spacer()
                Button { copy(c.log.joined(separator: "\n")) } label: { copyIcon(c.log.joined(separator: "\n")) }
                    .buttonStyle(.borderless).help("Copy log")
                Button { c.log.removeAll() } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Clear log")
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showLog = false }
                } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Close")
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(c.log.suffix(300).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(logColor(line))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(10)
                }
                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08)))
                .onChange(of: c.log.count) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .padding(.top, 34)
        .padding(.trailing, 18)
        .padding(.bottom, 18)
        .frame(width: 440)
        .frame(maxHeight: .infinity)
    }

    // สีตามระดับ: error = แดง, warning/retry = ส้ม, ที่เหลือ = เทา
    private func logColor(_ line: String) -> Color {
        let l = line.lowercased()
        if l.contains("error") || l.contains("failed") || l.contains("refused") || l.contains("denied") { return Color(red: 1, green: 0.45, blue: 0.45) }
        if l.contains("warn") || l.contains("retry") || l.contains("disconnected") { return .orange }
        return .white.opacity(0.72)
    }

    private func randomPin() -> String { String(format: "%06d", Int.random(in: 0...999_999)) }

    // URL ที่ต้องพิมพ์บน Tesla ในโหมด local (IP ของ Mac ในแต่ละวง)
    private var teslaURLs: some View {
        Card(title: "Open on Tesla", icon: "car.side") {
            VStack(alignment: .leading, spacing: 8) {
                if ips.isEmpty {
                    Text("No network found — turn on Internet Sharing or join a hotspot first").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(ips, id: \.ip) { item in
                    HStack(spacing: 8) {
                        let url = "https://\(item.ip):\(Controller.localHTTPS)"
                        Text(url).font(.system(.body, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                        Button { copy(url) } label: { copyIcon(url) }
                            .buttonStyle(.borderless).help("Copy")
                        Spacer()
                        Text(item.ip.hasPrefix("192.168.2.") ? "Internet Sharing" : item.name)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(verbatim: "Self-signed certificate: the first time, tap Advanced → Proceed\nIf Tesla refuses, try http://<IP>:\(Controller.localHTTP) instead")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("PIN: \(localPin)").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    Button { copy(localPin) } label: { copyIcon(localPin) }
                        .buttonStyle(.borderless).help("Copy PIN")
                    Spacer()
                    Button { ips = localIPv4s() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .buttonStyle(.borderless).font(.caption)
                }
            }
        }
    }

    // copy ลง clipboard แล้วเปลี่ยนไอคอนเป็น ✓ สักครู่
    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        copied = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == s { copied = "" } }
    }

    private func copyIcon(_ value: String) -> some View {
        Image(systemName: copied == value ? "checkmark" : "doc.on.doc")
            .foregroundStyle(copied == value ? Color.green : Color.secondary)
    }

    private func label(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // ปิดแอป -> หยุด mac-capture / ffmpeg / mac-input-agent ที่เป็น child process ด้วย
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Controller.shared.stop() }
    }
}

@main
struct TeslaDisplayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller = Controller.shared

    var body: some Scene {
        Window("Tesla Display", id: "main") {
            ContentView().environmentObject(controller)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.presented) // เปิดหน้าต่างทุกครั้ง แม้ครั้งก่อนจะปิดแอปตอนไม่มีหน้าต่าง
        .restorationBehavior(.disabled)
    }
}
