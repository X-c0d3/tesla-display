// Mac input agent: รับ touch/keyboard จาก Tesla (ผ่าน relay บน NAS) แล้วสั่งเมาส์/คีย์บอร์ดบน Mac
//
//   swiftc -O scripts/mac-input-agent.swift -o mac-input-agent
//   ./mac-input-agent list                       # ดูหมายเลขจอ (ใช้เลขเดียวกับ mac-publish.sh)
//   SCREEN_URL=https://screen.example.com TOKEN=<PUBLISH_TOKEN> ./mac-input-agent 1
//
// ต้องให้สิทธิ์ Accessibility แก่ Terminal (System Settings > Privacy & Security > Accessibility)
//
// ตัวเลือก (env):
//   CONTROL=0          ไม่รับ touch/keyboard (ใช้ต่อ relay เพื่อ signalling อย่างเดียว)
//   PAIR=1             โหมด Direct Wi-Fi: SCREEN_URL = pairing server, TOKEN = PIN
//                      รับ WebRTC offer จาก Tesla ผ่าน pairing server แล้วถาม mediamtx บน Mac (LOCAL_WHEP)
//                      -> ภาพวิ่งตรง Mac -> Tesla ใน Wi-Fi วงเดียวกัน
import ApplicationServices
import CoreGraphics
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

func activeDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return ids
}

let args = CommandLine.arguments
if args.count > 1 && args[1] == "list" {
    for (i, d) in activeDisplays().enumerated() {
        let b = CGDisplayBounds(d)
        print("\(i): \(Int(b.width))x\(Int(b.height)) at (\(Int(b.minX)),\(Int(b.minY)))\(CGDisplayIsMain(d) != 0 ? " main" : "")")
    }
    exit(0)
}

let env = ProcessInfo.processInfo.environment
guard args.count > 1, let index = Int(args[1]), env["SCREEN_URL"] != nil, env["TOKEN"] != nil else {
    print("usage: \(args[0]) list | SCREEN_URL=https://... TOKEN=... \(args[0]) <display-index>")
    print("       PAIR=1 SCREEN_URL=https://<pair server> TOKEN=<PIN> \(args[0]) <display-index>")
    exit(1)
}
let displays = activeDisplays()
guard index >= 0 && index < displays.count else {
    print("display \(index) not found (run: \(args[0]) list)")
    exit(1)
}
let display = displays[index]

let axPrompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
if !AXIsProcessTrustedWithOptions(axPrompt) {
    print("! No Accessibility permission: allow it in System Settings, then run again")
}

// virtual keycodes (ANSI layout)
let namedKeys: [String: CGKeyCode] = [
    "Enter": 36, "Tab": 48, "Backspace": 51, "Escape": 53, "Delete": 117,
    "ArrowLeft": 123, "ArrowRight": 124, "ArrowDown": 125, "ArrowUp": 126,
    "Home": 115, "End": 119, "PageUp": 116, "PageDown": 121, " ": 49,
]
let charKeys: [Character: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
    "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
    "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
    "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
]
let modFlags: [String: CGEventFlags] = [
    "cmd": .maskCommand, "alt": .maskAlternate, "ctrl": .maskControl, "shift": .maskShift,
]

// จอย (Gamepad API "standard" layout) -> คีย์บอร์ด/เมาส์ เพราะ macOS ไม่ให้สร้างจอยเสมือนโดยไม่มี entitlement
//   A=Space  B=Esc  X=E  Y=Q  LB=Shift  RB=R  LT=คลิกขวา  RT=คลิกซ้าย  Back=Tab  Start=Return
//   D-pad=ลูกศร  อนาล็อกซ้าย=WASD  อนาล็อกขวา=เลื่อนเมาส์
let padButtonKeys: [Int: CGKeyCode] = [
    0: 49, 1: 53, 2: 14, 3: 12, 4: 56, 5: 15, 8: 48, 9: 36,
    12: 126, 13: 125, 14: 123, 15: 124,
]
let padMouseButtons: [Int: CGMouseButton] = [6: .right, 7: .left]

final class Injector {
    var padPrev: [Int: [Int]] = [:]  // ปุ่มที่กดอยู่ของจอยแต่ละตัว
    var stickKeys: Set<CGKeyCode> = []  // WASD ที่กดค้างจากอนาล็อกซ้าย
    let src = CGEventSource(stateID: .hidSystemState)
    var pos = CGPoint.zero
    var button = CGMouseButton.left
    var isDown = false
    var lastClick = Date.distantPast
    var lastClickPos = CGPoint.zero
    var clickCount: Int64 = 1

    func point(_ m: [String: Any]) -> CGPoint {
        let b = CGDisplayBounds(display)
        let x = (m["x"] as? Double) ?? 0, y = (m["y"] as? Double) ?? 0
        return CGPoint(x: b.minX + x * (b.width - 1), y: b.minY + y * (b.height - 1))
    }

    func mouse(_ type: CGEventType) {
        guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: pos, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: clickCount)
        e.post(tap: .cghidEventTap)
    }

    func key(_ code: CGKeyCode, _ flags: CGEventFlags) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
    }

    func keyState(_ code: CGKeyCode, down: Bool) {
        CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)?.post(tap: .cghidEventTap)
    }

    func pad(_ m: [String: Any]) {
        let id = (m["i"] as? Int) ?? 0
        let buttons = (m["b"] as? [Int]) ?? []
        let axes = (m["a"] as? [Double]) ?? []
        let prev = padPrev[id] ?? []
        for (i, v) in buttons.enumerated() {
            let was = i < prev.count ? prev[i] : 0
            guard v != was else { continue }
            if let code = padButtonKeys[i] {
                keyState(code, down: v == 1)
            } else if let mb = padMouseButtons[i] {
                pos = CGEvent(source: nil)?.location ?? pos
                button = mb
                let type: CGEventType = mb == .left ? (v == 1 ? .leftMouseDown : .leftMouseUp)
                                                    : (v == 1 ? .rightMouseDown : .rightMouseUp)
                isDown = v == 1
                clickCount = 1
                mouse(type)
            }
        }
        padPrev[id] = buttons

        // อนาล็อกซ้าย -> WASD (กดค้างเมื่อโยกเกินครึ่ง)
        if axes.count >= 2 {
            var want: Set<CGKeyCode> = []
            if axes[1] < -0.5 { want.insert(13) }  // W
            if axes[1] > 0.5 { want.insert(1) }    // S
            if axes[0] < -0.5 { want.insert(0) }   // A
            if axes[0] > 0.5 { want.insert(2) }    // D
            for k in want.subtracting(stickKeys) { keyState(k, down: true) }
            for k in stickKeys.subtracting(want) { keyState(k, down: false) }
            stickKeys = want
        }

        // อนาล็อกขวา -> เลื่อนเมาส์แบบ relative (~1200 px/วินาที ที่ 60 Hz เมื่อโยกสุด)
        if axes.count >= 4, axes[2] != 0 || axes[3] != 0 {
            let dx = axes[2] * 20, dy = axes[3] * 20
            let cur = CGEvent(source: nil)?.location ?? pos
            let b = CGDisplayBounds(display)
            pos = CGPoint(x: min(max(cur.x + dx, b.minX), b.maxX - 1), y: min(max(cur.y + dy, b.minY), b.maxY - 1))
            let type: CGEventType = isDown ? (button == .left ? .leftMouseDragged : .rightMouseDragged) : .mouseMoved
            if let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: pos, mouseButton: button) {
                e.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
                e.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
                e.post(tap: .cghidEventTap)
            }
        }
    }

    func type(_ s: String) {
        for ch in s {
            if ch == "\n" { key(36, []); continue }
            var utf16 = Array(String(ch).utf16)
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
                e.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                e.post(tap: .cghidEventTap)
            }
        }
    }

    func handle(_ m: [String: Any]) {
        switch m["t"] as? String {
        case "down":
            pos = point(m)
            button = (m["b"] as? Int) == 2 ? .right : .left
            let now = Date()
            if now.timeIntervalSince(lastClick) < 0.4 && hypot(pos.x - lastClickPos.x, pos.y - lastClickPos.y) < 12 {
                clickCount += 1
            } else {
                clickCount = 1
            }
            lastClick = now
            lastClickPos = pos
            isDown = true
            mouse(button == .left ? .leftMouseDown : .rightMouseDown)
        case "move":
            pos = point(m)
            mouse(isDown ? (button == .left ? .leftMouseDragged : .rightMouseDragged) : .mouseMoved)
        case "up":
            if m["x"] != nil { pos = point(m) }
            mouse(button == .left ? .leftMouseUp : .rightMouseUp)
            isDown = false
        case "scroll":
            let dy = Int32((m["dy"] as? Double) ?? 0), dx = Int32((m["dx"] as? Double) ?? 0)
            CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)?
                .post(tap: .cghidEventTap)
        case "pad":
            pad(m)
        case "text":
            type((m["s"] as? String) ?? "")
        case "key":
            guard let k = m["key"] as? String else { return }
            var flags = CGEventFlags()
            for name in (m["mods"] as? [String]) ?? [] { if let f = modFlags[name] { flags.insert(f) } }
            if let code = namedKeys[k] ?? (k.count == 1 ? charKeys[Character(k.lowercased())] : nil) {
                key(code, flags)
            } else if flags.isEmpty {
                type(k)
            }
        default:
            break
        }
    }
}

final class Client: NSObject, URLSessionWebSocketDelegate {
    let injector = Injector()
    let url: URL
    let token: String
    let index: Int
    let control = env["CONTROL"] != "0"
    let pair = env["PAIR"] == "1"
    let localWHEP = URL(string: env["LOCAL_WHEP"] ?? "http://127.0.0.1:8889/screen/whep")!
    var task: URLSessionWebSocketTask?
    lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    init(base: String, token: String, index: Int) {
        self.token = token
        self.index = index
        var c = URLComponents(string: base)!
        c.scheme = c.scheme == "https" ? "wss" : "ws"
        c.path = (c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path) + "/input/agent"
        url = c.url!
    }

    func connect() {
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        let auth = try! JSONSerialization.data(withJSONObject: ["auth": self.token])
        t.send(.string(String(data: auth, encoding: .utf8)!)) { _ in }
        receive(t)
    }

    func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self, t === self.task else { return }
            switch result {
            case .failure(let err):
                print("disconnected: \(err.localizedDescription) — retrying")
                self.task = nil
                t.cancel()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { self.connect() }
            case .success(let msg):
                if case .string(let s) = msg,
                   let m = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] {
                    switch m["t"] as? String {
                    case "ok":
                        print("connected to \(self.url.host ?? "") — display \(self.index), control \(self.control ? "on" : "off")")
                    case "denied": print(self.pair ? "PIN rejected by pairing server (min 6 characters)" : "token denied"); exit(1)
                    case "busy": print("pairing server is busy — retrying")
                    case "screen": reportViewerScreen(m)
                    case "offer" where self.pair: self.answerOffer(m)
                    default: if self.control { self.injector.handle(m) }
                    }
                }
                self.receive(t)
            }
        }
    }

    // Direct Wi-Fi: offer จาก Tesla (ผ่าน pairing server) -> mediamtx บน Mac -> answer กลับไปทางเดิม
    // answer มี IP ของ Mac ใน Wi-Fi วงนั้น -> Tesla ต่อ UDP ตรงมาที่ Mac
    func answerOffer(_ m: [String: Any]) {
        guard let id = m["id"] as? String, let sdp = m["sdp"] as? String else { return }
        var req = URLRequest(url: localWHEP)
        req.httpMethod = "POST"
        req.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(sdp.utf8)
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            var reply: [String: Any] = ["t": "answer", "id": id]
            if code == 201 || code == 200, let data, let answer = String(data: data, encoding: .utf8) {
                reply["sdp"] = answer
            } else {
                reply["error"] = code == 404 ? "Mac is not sending video yet" : "Mac video server: \(err?.localizedDescription ?? "HTTP \(code)")"
            }
            self?.sendJSON(reply)
        }.resume()
    }

    func sendJSON(_ o: [String: Any]) {
        guard let t = task, let d = try? JSONSerialization.data(withJSONObject: o),
              let s = String(data: d, encoding: .utf8) else { return }
        t.send(.string(s)) { _ in }
    }
}

// แจ้งขนาดจอ Tesla ให้แอปทาง stdout (แอปอ่านบรรทัดนี้เพื่อทำ Resolution: Auto)
func reportViewerScreen(_ m: [String: Any]) {
    let w = (m["w"] as? Double) ?? 0, h = (m["h"] as? Double) ?? 0, dpr = (m["dpr"] as? Double) ?? 1
    guard w > 0, h > 0 else { return }
    print("viewer-screen \(Int(w)) \(Int(h)) \(dpr)")
}

let client = Client(base: env["SCREEN_URL"]!, token: env["TOKEN"]!, index: index)
client.connect()
dispatchMain()
