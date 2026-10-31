// จับภาพหน้าจอด้วย ScreenCaptureKit แล้วเขียนเฟรม NV12 แบบ raw ออก stdout (ใช้คู่กับ ffmpeg ใน mac-publish.sh)
// ffmpeg avfoundation จับภาพจอบน macOS ใหม่ๆ ไม่ได้แล้ว จึงต้องใช้ตัวนี้แทน
//
//   mac-capture list
//   mac-capture size <display> [1920x1200]       # พิมพ์ "W H" ที่ย่อให้พอดีกรอบโดยรักษาสัดส่วน
//   mac-capture stream <display> <W> <H> <fps> [audio-fifo]
//                                                # raw nv12 -> stdout, เสียงระบบ f32le 48kHz stereo -> audio-fifo
//
// ต้องให้สิทธิ์ Screen Recording แก่ Terminal
import AppKit
import CoreAudio
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func activeDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return ids
}

let args = CommandLine.arguments
let usage = "usage: mac-capture list | size <display> [WxH] | stream <display> <W> <H> <fps> [audio-fifo]"
guard args.count >= 2 else { log(usage); exit(1) }

if args[1] == "list" {
    var names: [CGDirectDisplayID: String] = [:]
    for s in NSScreen.screens {
        if let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            names[id] = s.localizedName
        }
    }
    for (i, d) in activeDisplays().enumerated() {
        let b = CGDisplayBounds(d)
        let name = names[d] ?? "Display \(d)"
        print("\(i): \(name) — \(Int(b.width))x\(Int(b.height))\(CGDisplayIsMain(d) != 0 ? " (main)" : "")")
    }
    exit(0)
}

guard args.count >= 3, let index = Int(args[2]) else { log(usage); exit(1) }
let displays = activeDisplays()
guard index >= 0 && index < displays.count else { log("display \(index) not found (run: mac-capture list)"); exit(1) }
let displayID = displays[index]

if args[1] == "size" {
    let b = CGDisplayBounds(displayID)
    var w = b.width, h = b.height
    let box = args.count > 3 ? args[3].split(separator: "x").compactMap { Double($0) } : []
    if box.count == 2 {
        let s = min(1, box[0] / w, box[1] / h)
        w *= s
        h *= s
    }
    print("\(Int(w) / 2 * 2) \(Int(h) / 2 * 2)")
    exit(0)
}

guard args[1] == "stream", args.count >= 6, let W = Int(args[3]), let H = Int(args[4]), let fps = Int(args[5]) else {
    log(usage)
    exit(1)
}
let audioPath = args.count > 6 ? args[6] : nil

final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    let w: Int, h: Int
    var frame: [UInt8]
    var hasFrame = false
    let lock = NSLock()

    init(w: Int, h: Int) {
        self.w = w
        self.h = h
        frame = [UInt8](repeating: 0, count: w * h * 3 / 2)
    }

    var audioOut: FileHandle?

    // เสียงระบบ -> f32le interleaved stereo ลง FIFO ให้ ffmpeg (เปิด FIFO ครั้งแรกจะรอจน ffmpeg เปิดอ่าน)
    func writeAudio(_ sb: CMSampleBuffer) {
        guard let path = audioPath else { return }
        if audioOut == nil { audioOut = FileHandle(forWritingAtPath: path) }
        guard let out = audioOut else { return }
        var size = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: &size, bufferListOut: nil,
            bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard size > 0 else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { raw.deallocate() }
        let ablPtr = raw.assumingMemoryBound(to: AudioBufferList.self)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: nil, bufferListOut: ablPtr,
            bufferListSize: size, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block) == noErr else { return }
        let list = UnsafeMutableAudioBufferListPointer(ablPtr)
        var data: Data
        if list.count >= 2, let l = list[0].mData, let r = list[1].mData {
            // planar L/R -> interleaved
            let frames = Int(list[0].mDataByteSize) / 4
            let lp = l.assumingMemoryBound(to: Float.self), rp = r.assumingMemoryBound(to: Float.self)
            var interleaved = [Float](repeating: 0, count: frames * 2)
            for i in 0..<frames {
                interleaved[i * 2] = lp[i]
                interleaved[i * 2 + 1] = rp[i]
            }
            data = interleaved.withUnsafeBufferPointer { Data(buffer: $0) }
        } else if list.count == 1, let p = list[0].mData {
            let channels = Int(list[0].mNumberChannels)
            data = Data(bytes: p, count: Int(list[0].mDataByteSize))
            if channels == 1 { // mono -> stereo
                let mono = p.assumingMemoryBound(to: Float.self)
                let frames = Int(list[0].mDataByteSize) / 4
                var st = [Float](repeating: 0, count: frames * 2)
                for i in 0..<frames { st[i * 2] = mono[i]; st[i * 2 + 1] = mono[i] }
                data = st.withUnsafeBufferPointer { Data(buffer: $0) }
            }
        } else {
            return
        }
        out.write(data)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            if sb.isValid { writeAudio(sb) }
            return
        }
        guard type == .screen, sb.isValid, let pb = sb.imageBuffer else { return }
        if let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
           let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) != .complete {
            return // idle/blank frame: ส่งเฟรมเดิมซ้ำแทน
        }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        lock.lock()
        defer { lock.unlock() }
        frame.withUnsafeMutableBytes { dst in
            var offset = 0
            for plane in 0..<2 { // Y แล้วตามด้วย CbCr (interleaved) ความกว้างเท่ากันเป็น byte
                let rows = plane == 0 ? h : h / 2
                guard let src = CVPixelBufferGetBaseAddressOfPlane(pb, plane) else { return }
                let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
                let rowBytes = min(w, stride)
                for r in 0..<min(rows, CVPixelBufferGetHeightOfPlane(pb, plane)) {
                    memcpy(dst.baseAddress! + offset + r * w, src + r * stride, rowBytes)
                }
                offset += w * rows
            }
        }
        hasFrame = true
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("capture stopped: \(error.localizedDescription)")
        exit(1)
    }
}

signal(SIGPIPE, SIG_DFL) // ffmpeg ปิด -> จบโปรแกรม
let capture = Capture(w: W, h: H)
let out = FileHandle.standardOutput

// ScreenCaptureKit ส่งเฟรมเฉพาะตอนจอเปลี่ยน -> เขียนเฟรมล่าสุดออกด้วยอัตราคงที่ให้ ffmpeg
let ticker = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "out", qos: .userInteractive))
ticker.schedule(deadline: .now(), repeating: 1.0 / Double(fps), leeway: .milliseconds(1))
ticker.setEventHandler {
    capture.lock.lock()
    let data = capture.hasFrame ? Data(capture.frame) : nil
    capture.lock.unlock()
    if let data { out.write(data) }
}

var activeStream: SCStream?
SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
    guard let content else {
        log("cannot access screen: \(error?.localizedDescription ?? "unknown") — grant Screen Recording permission, then run again")
        exit(1)
    }
    guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
        log("display \(index) not available to ScreenCaptureKit")
        exit(1)
    }
    let cfg = SCStreamConfiguration()
    cfg.width = W
    cfg.height = H
    cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
    cfg.showsCursor = true
    cfg.queueDepth = 5
    if audioPath != nil {
        cfg.capturesAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 2
        cfg.excludesCurrentProcessAudio = true
    }
    let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: capture)
    do {
        try stream.addStreamOutput(capture, type: .screen, sampleHandlerQueue: DispatchQueue(label: "capture", qos: .userInteractive))
        if audioPath != nil {
            try stream.addStreamOutput(capture, type: .audio, sampleHandlerQueue: DispatchQueue(label: "audio", qos: .userInteractive))
        }
    } catch {
        log("addStreamOutput failed: \(error.localizedDescription)")
        exit(1)
    }
    stream.startCapture { error in
        if let error {
            log("start capture failed: \(error.localizedDescription)")
            exit(1)
        }
        log("capturing display \(index) at \(W)x\(H) @ \(fps)fps\(audioPath != nil ? " + audio" : "")")
        ticker.resume()
    }
    activeStream = stream
}
dispatchMain()
