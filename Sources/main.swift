import AppKit
import AVFoundation
import CoreAudio
import AudioToolbox
import Carbon.HIToolbox

// MARK: - Helpers

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
}

struct RecError: Error { let msg: String }

func fmtTime(_ s: Int) -> String {
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%02d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
}

let recDir: URL = {
    let u = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Aura")
    try? FileManager.default.createDirectory(at: u.appendingPathComponent(".raw"), withIntermediateDirectories: true)
    return u
}()

// MARK: - Ogg Opus writer

final class OggWriter {
    let handle: FileHandle
    let serial: UInt32 = 0x41555241
    var seq: UInt32 = 0
    static let table: [UInt32] = (0..<256).map { i in
        var r = UInt32(i) << 24
        for _ in 0..<8 { r = (r & 0x8000_0000) != 0 ? (r << 1) ^ 0x04c1_1db7 : r << 1 }
        return r
    }
    init(handle: FileHandle) { self.handle = handle }

    func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xff) } }
    func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xff) } }

    func page(_ packets: [Data], granule: UInt64, flags: UInt8) {
        var segs = [UInt8](), body = Data()
        for p in packets {
            var n = p.count
            while n >= 255 { segs.append(255); n -= 255 }
            segs.append(UInt8(n))
            body.append(p)
        }
        var h: [UInt8] = [UInt8]("OggS".utf8)
        h.append(contentsOf: [0, flags] as [UInt8])
        h.append(contentsOf: le64(granule))
        h.append(contentsOf: le32(serial))
        h.append(contentsOf: le32(seq))
        h.append(contentsOf: [0, 0, 0, 0] as [UInt8])
        seq += 1
        h.append(UInt8(segs.count))
        h += segs
        var pg = h + [UInt8](body)
        var c: UInt32 = 0
        for b in pg { c = (c << 8) ^ Self.table[Int(((c >> 24) & 0xff) ^ UInt32(b))] }
        pg.replaceSubrange(22..<26, with: le32(c))
        handle.write(Data(pg))
    }

    func headers(preSkip: UInt16) {
        var head: [UInt8] = [UInt8]("OpusHead".utf8)
        head.append(contentsOf: [1, 1, UInt8(preSkip & 0xff), UInt8(preSkip >> 8)] as [UInt8])
        head.append(contentsOf: le32(48000))
        head.append(contentsOf: [0, 0, 0] as [UInt8])
        page([Data(head)], granule: 0, flags: 0x02)
        let vendor = [UInt8]("Aura".utf8)
        var tags: [UInt8] = [UInt8]("OpusTags".utf8)
        tags.append(contentsOf: le32(UInt32(vendor.count)))
        tags.append(contentsOf: vendor)
        tags.append(contentsOf: le32(0))
        page([Data(tags)], granule: 0, flags: 0)
    }
}

final class Feeder {
    let file: AVAudioFile
    let buf: AVAudioPCMBuffer
    init(file: AVAudioFile) {
        self.file = file
        buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 960)!
    }
}

let feedProc: AudioConverterComplexInputDataProc = { _, ioNum, ioData, _, user in
    let f = Unmanaged<Feeder>.fromOpaque(user!).takeUnretainedValue()
    f.buf.frameLength = 0
    if f.file.framePosition < f.file.length { try? f.file.read(into: f.buf, frameCount: 960) }
    let n = Int(f.buf.frameLength)
    if n == 0 { ioNum.pointee = 0; return noErr }
    let p = f.buf.floatChannelData![0]
    if n < 960 { for i in n..<960 { p[i] = 0 } }
    f.buf.frameLength = 960
    ioData.pointee.mNumberBuffers = 1
    ioData.pointee.mBuffers.mNumberChannels = 1
    ioData.pointee.mBuffers.mDataByteSize = 960 * 4
    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(p)
    ioNum.pointee = 960
    return noErr
}

func encodeOpus(src: URL, dst: URL, kbps: Int) throws {
    let file = try AVAudioFile(forReading: src)
    var inDesc = file.processingFormat.streamDescription.pointee
    var outDesc = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                              mBytesPerPacket: 0, mFramesPerPacket: 960, mBytesPerFrame: 0,
                                              mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
    var conv: AudioConverterRef?
    guard AudioConverterNew(&inDesc, &outDesc, &conv) == noErr, let c = conv else { throw RecError(msg: "Opus encoder недоступен") }
    defer { AudioConverterDispose(c) }
    var br = UInt32(kbps * 1000)
    AudioConverterSetProperty(c, kAudioConverterEncodeBitRate, 4, &br)

    var prime = AudioConverterPrimeInfo()
    var psz = UInt32(MemoryLayout<AudioConverterPrimeInfo>.size)
    AudioConverterGetProperty(c, kAudioConverterPrimeInfo, &psz, &prime)
    let preSkip = UInt16(prime.leadingFrames > 0 ? min(prime.leadingFrames, 65535) : 312)

    FileManager.default.createFile(atPath: dst.path, contents: nil)
    let fh = try FileHandle(forWritingTo: dst)
    defer { try? fh.close() }
    let ogg = OggWriter(handle: fh)
    ogg.headers(preSkip: preSkip)

    let feeder = Feeder(file: file)
    let ptr = Unmanaged.passUnretained(feeder).toOpaque()
    let out = UnsafeMutablePointer<UInt8>.allocate(capacity: 8192)
    defer { out.deallocate() }
    var pending: [Data] = []
    var packets: UInt64 = 0

    while true {
        var n: UInt32 = 1
        var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 8192, mData: out))
        var pd = AudioStreamPacketDescription()
        let st = AudioConverterFillComplexBuffer(c, feedProc, ptr, &n, &abl, &pd)
        if n == 0 { break }
        pending.append(Data(bytes: out, count: Int(abl.mBuffers.mDataByteSize)))
        packets += 1
        if pending.count >= 40 {
            ogg.page(pending, granule: packets * 960, flags: 0)
            pending.removeAll()
        }
        if st != noErr { break }
    }
    if pending.isEmpty { pending = [Data()] }
    ogg.page(pending, granule: packets * 960, flags: 0x04)
}

// MARK: - Recorder (system audio tap + microphone -> mono 48k)

final class Recorder {
    private let q = DispatchQueue(label: "aura.mix")
    private let ioq = DispatchQueue(label: "aura.io", qos: .userInitiated)
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
    private var mic: [Float] = [], sys: [Float] = []
    private var file: AVAudioFile?
    private var timer: DispatchSourceTimer?
    private var paused = false

    private let engine = AVAudioEngine()
    private var micConv: AVAudioConverter?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var sysConv: AVAudioConverter?
    private var tapFormat: AVAudioFormat?
    private(set) var micActive = false

    func start(to url: URL) throws {
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        mic = []; sys = []; paused = false
        try startTap()
        startMic()
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in self?.flush(final: false) }
        t.resume()
        timer = t
    }

    func setPaused(_ p: Bool) { q.async { self.paused = p; if p { self.mic = []; self.sys = [] } } }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let p = procID { AudioDeviceStop(aggID, p); AudioDeviceDestroyIOProcID(aggID, p); procID = nil }
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID); aggID = kAudioObjectUnknown }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = kAudioObjectUnknown }
        timer?.cancel(); timer = nil
        q.sync { flush(final: true); file = nil }
    }

    // System audio
    private func startTap() throws {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr else {
            throw RecError(msg: "Нет доступа к системному звуку. Разреши в Настройки → Конфиденциальность → Запись системного звука")
        }
        var a = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var sz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioObjectGetPropertyData(tapID, &a, 0, nil, &sz, &asbd)
        guard let fmt = AVAudioFormat(streamDescription: &asbd) else { throw RecError(msg: "Неподдерживаемый формат системного звука") }
        tapFormat = fmt
        sysConv = AVAudioConverter(from: fmt, to: target)

        var dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Aura Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]
        if let uid = Self.defaultOutputUID() {
            dict[kAudioAggregateDeviceMainSubDeviceKey] = uid
            dict[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: uid]]
        }
        guard AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggID) == noErr else {
            throw RecError(msg: "Не удалось создать аудио-устройство для записи")
        }
        let st = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, ioq) { [weak self] _, inData, _, _, _ in
            guard let self, let fmt = self.tapFormat, let conv = self.sysConv,
                  let buf = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: inData) else { return }
            let samples = self.convert(buf, conv)
            self.q.async { if !self.paused { self.sys.append(contentsOf: samples) } }
        }
        guard st == noErr, AudioDeviceStart(aggID, procID) == noErr else { throw RecError(msg: "Не удалось запустить захват системного звука") }
    }

    // Microphone
    private func startMic() {
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0, let conv = AVAudioConverter(from: fmt, to: target) else { return }
        micConv = conv
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in
            guard let self, let conv = self.micConv else { return }
            let samples = self.convert(buf, conv)
            self.q.async { if !self.paused { self.mic.append(contentsOf: samples) } }
        }
        do { try engine.start(); micActive = true } catch { micActive = false }
    }

    private func convert(_ buf: AVAudioPCMBuffer, _ conv: AVAudioConverter) -> [Float] {
        let cap = AVAudioFrameCount(Double(buf.frameLength) * 48000 / buf.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return [] }
        var given = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true; status.pointee = .haveData; return buf
        }
        guard out.frameLength > 0, let p = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: p, count: Int(out.frameLength)))
    }

    // Mix both FIFOs; if one source lags >0.5s (silent device), pad it with zeros.
    private func flush(final: Bool) {
        let a = mic.count, b = sys.count
        var n = min(a, b)
        if final { n = max(a, b) }
        else if max(a, b) > 24000 { n = max(a, b) - 4800 }
        guard n > 0, let file, let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(n)) else { return }
        let p = out.floatChannelData![0]
        for i in 0..<n {
            let m = i < a ? mic[i] : 0, s = i < b ? sys[i] : 0
            p[i] = max(-1, min(1, m + s))
        }
        out.frameLength = AVAudioFrameCount(n)
        try? file.write(from: out)
        mic.removeFirst(min(n, a)); sys.removeFirst(min(n, b))
    }

    static func defaultOutputUID() -> String? {
        var dev = AudioObjectID(0)
        var sz = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &dev) == noErr else { return nil }
        var uid: Unmanaged<CFString>?
        sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        a.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &uid) == noErr, let u = uid else { return nil }
        return u.takeRetainedValue() as String
    }
}

func deviceName(_ selector: AudioObjectPropertySelector) -> String {
    var dev = AudioObjectID(0)
    var sz = UInt32(MemoryLayout<AudioObjectID>.size)
    var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &dev) == noErr, dev != 0 else { return "не найдено" }
    var name: Unmanaged<CFString>?
    sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    a.mSelector = kAudioObjectPropertyName
    guard AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &name) == noErr, let n = name else { return "не найдено" }
    return n.takeRetainedValue() as String
}

// MARK: - UI

final class Btn: NSButton {
    var onTap: (() -> Void)?
    @objc func fire() { onTap?() }
    init(_ title: String, symbol: String? = nil, fg: NSColor, bg: NSColor?, border: NSColor? = nil,
         size: CGFloat = 13, height: CGFloat = 36, radius: CGFloat = 8, mono: Bool = false, tap: @escaping () -> Void) {
        super.init(frame: .zero)
        onTap = tap
        target = self; action = #selector(fire)
        isBordered = false; wantsLayer = true
        layer?.cornerRadius = radius
        layer?.backgroundColor = bg?.cgColor
        if let border { layer?.borderColor = border.cgColor; layer?.borderWidth = 1 }
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: fg, .font: font]
        let str = NSMutableAttributedString()
        if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size - 2, weight: .semibold).applying(.init(paletteColors: [fg]))) {
            let att = NSTextAttachment(); att.image = img
            att.bounds = CGRect(x: 0, y: -1, width: img.size.width, height: img.size.height)
            str.append(NSAttributedString(attachment: att))
        }
        str.append(NSAttributedString(string: title, attributes: attrs))
        attributedTitle = str
        alignment = .center
        heightAnchor.constraint(equalToConstant: height).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
}

enum Mode { case idle, recording, paused, stopped }

let fgMain = NSColor(hex: 0xededed), fgDim = NSColor(hex: 0xa1a1a1), fgMuted = NSColor(hex: 0x8f8f8f)
let bgPanel = NSColor(hex: 0x0a0a0a), lineCol = NSColor(hex: 0x333333)

var hotkeyHandler: (() -> Void)?

final class App: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    let stack = NSStackView()
    let recorder = Recorder()

    var mode = Mode.idle
    var accumulated = 0.0
    var runningSince: Date?
    var tick: Timer?
    var rawURL: URL?
    var rateIdx = 2
    let rates = [64, 96, 128]
    var savedURL: URL?
    var savedSize = 0
    var exporting = false
    var notice: String?

    var elapsed: Int { Int(accumulated + (runningSince.map { Date().timeIntervalSince($0) } ?? 0)) }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        let vc = NSViewController()
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = bgPanel.cgColor
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            root.widthAnchor.constraint(equalToConstant: 300),
        ])
        vc.view = root
        popover.contentViewController = vc
        registerHotkey()
        render()
    }

    func applicationWillTerminate(_ n: Notification) {
        if mode == .recording || mode == .paused { recorder.stop() }
    }

    func registerHotkey() {
        hotkeyHandler = { [weak self] in self?.hotkey() }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in hotkeyHandler?(); return noErr }, 1, &spec, nil, nil)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(cmdKey | shiftKey), EventHotKeyID(signature: 0x41555241, id: 1),
                            GetApplicationEventTarget(), 0, &ref)
    }

    func hotkey() {
        switch mode {
        case .idle: start()
        case .recording, .paused: stop()
        case .stopped: break
        }
    }

    @objc func togglePopover() {
        if popover.isShown { popover.performClose(nil) }
        else if let b = item.button {
            render()
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: actions

    func start() {
        notice = nil
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            DispatchQueue.main.async { self?.beginRecording() }
        }
    }

    func beginRecording() {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let url = recDir.appendingPathComponent(".raw/\(f.string(from: Date())).caf")
        do {
            try recorder.start(to: url)
        } catch let e as RecError {
            recorder.stop(); notice = e.msg; render(); return
        } catch {
            recorder.stop(); notice = error.localizedDescription; render(); return
        }
        if !recorder.micActive { notice = "Микрофон недоступен — пишется только системный звук" }
        rawURL = url; accumulated = 0; runningSince = Date(); mode = .recording
        savedURL = nil
        tick = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.updateTimer() }
        RunLoop.main.add(tick!, forMode: .common)
        render()
    }

    func togglePause() {
        if mode == .recording {
            accumulated += Date().timeIntervalSince(runningSince ?? Date()); runningSince = nil
            mode = .paused; recorder.setPaused(true)
        } else {
            runningSince = Date(); mode = .recording; recorder.setPaused(false)
        }
        render()
    }

    func stop() {
        if let r = runningSince { accumulated += Date().timeIntervalSince(r); runningSince = nil }
        recorder.stop()
        tick?.invalidate(); tick = nil
        mode = .stopped; savedURL = nil
        render()
    }

    func export() {
        guard let raw = rawURL else { return }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH-mm"
        var dst = recDir.appendingPathComponent("Call \(f.string(from: Date())).opus")
        var i = 2
        while FileManager.default.fileExists(atPath: dst.path) {
            dst = recDir.appendingPathComponent("Call \(f.string(from: Date())) \(i).opus"); i += 1
        }
        exporting = true; notice = nil; render()
        let kbps = rates[rateIdx], out = dst
        DispatchQueue.global(qos: .userInitiated).async {
            var err: String?
            do { try encodeOpus(src: raw, dst: out, kbps: kbps) } catch let e as RecError { err = e.msg } catch { err = error.localizedDescription }
            DispatchQueue.main.async {
                self.exporting = false
                if let err { self.notice = err }
                else {
                    try? FileManager.default.removeItem(at: raw)
                    self.savedURL = out
                    self.savedSize = ((try? FileManager.default.attributesOfItem(atPath: out.path)[.size]) as? Int) ?? 0
                    NSWorkspace.shared.activateFileViewerSelecting([out])
                }
                self.render()
            }
        }
    }

    func reset() {
        if savedURL == nil, let raw = rawURL { try? FileManager.default.removeItem(at: raw) }
        rawURL = nil; savedURL = nil; accumulated = 0; mode = .idle; notice = nil
        render()
    }

    func updateTimer() {
        item.button?.attributedTitle = trayTitle()
        timerLabel?.stringValue = fmtTime(elapsed)
    }

    // MARK: render

    var timerLabel: NSTextField?

    func label(_ s: String, size: CGFloat, color: NSColor, mono: Bool = false, weight: NSFont.Weight = .regular) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.textColor = color
        t.font = mono ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        return t
    }

    func trayTitle() -> NSAttributedString {
        guard mode == .recording || mode == .paused else { return NSAttributedString(string: "") }
        return NSAttributedString(string: " " + fmtTime(elapsed), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .baselineOffset: 0.5])
    }

    func trayImage() -> NSImage {
        let active = mode == .recording || mode == .paused
        let live = mode == .recording
        let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: 2.5, dy: 2.5))
            ring.lineWidth = 1.4
            NSColor.black.setStroke(); ring.stroke()
            let d: CGFloat = active ? 5 : 3
            let dot = NSBezierPath(ovalIn: NSRect(x: 8 - d, y: 8 - d, width: d * 2, height: d * 2))
            (live ? NSColor(hex: 0xff4d4d) : NSColor.black).setFill(); dot.fill()
            return true
        }
        img.isTemplate = !live
        return img
    }

    func render() {
        item.button?.image = trayImage()
        item.button?.imagePosition = .imageLeading
        item.button?.attributedTitle = trayTitle()

        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        func padded(_ v: NSView, top: CGFloat = 0, h: CGFloat = 10, bottom: CGFloat = 0) -> NSView {
            let c = NSView(); v.translatesAutoresizingMaskIntoConstraints = false; c.addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: c.topAnchor, constant: top), v.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -bottom),
                v.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: h), v.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -h),
            ])
            c.translatesAutoresizingMaskIntoConstraints = false
            c.widthAnchor.constraint(equalToConstant: 300).isActive = true
            return c
        }

        // header
        let labels: [Mode: String] = [.idle: "Готов", .recording: "Запись", .paused: "Пауза", .stopped: "Завершено"]
        let dotColor: [Mode: NSColor] = [.idle: NSColor(hex: 0x555555), .recording: NSColor(hex: 0xff4d4d), .paused: fgMain, .stopped: NSColor(hex: 0x555555)]
        let dot = NSView(); dot.wantsLayer = true; dot.layer?.cornerRadius = 3; dot.layer?.backgroundColor = dotColor[mode]!.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 6).isActive = true; dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
        let status = NSStackView(views: [dot, label(labels[mode]!, size: 12, color: fgDim)]); status.spacing = 8
        let t = label(fmtTime(elapsed), size: 22, color: mode == .idle ? NSColor(hex: 0x555555) : fgMain, mono: true, weight: .medium)
        timerLabel = t
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [status, spacer, t]); header.distribution = .fill; header.alignment = .centerY
        stack.addArrangedSubview(padded(header, top: 14, h: 14, bottom: 4))

        // devices
        if mode != .stopped {
            func row(_ k: String, _ v: String) -> NSView {
                let key = label(k, size: 11, color: fgMuted, mono: true)
                key.translatesAutoresizingMaskIntoConstraints = false
                key.widthAnchor.constraint(equalToConstant: 64).isActive = true
                let val = label(v, size: 11, color: fgMain, mono: true)
                val.lineBreakMode = .byTruncatingTail
                val.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let r = NSStackView(views: [key, val]); r.spacing = 6; r.alignment = .firstBaseline
                return r
            }
            let dev = NSStackView(views: [
                row("Микрофон", deviceName(kAudioHardwarePropertyDefaultInputDevice)),
                row("Системный", deviceName(kAudioHardwarePropertyDefaultSystemOutputDevice)),
            ])
            dev.orientation = .vertical; dev.alignment = .leading; dev.spacing = 4
            stack.addArrangedSubview(padded(dev, top: 0, h: 14, bottom: 4))
        }

        // notice
        if let notice {
            let box = NSView(); box.wantsLayer = true; box.layer?.cornerRadius = 8; box.layer?.backgroundColor = fgMain.cgColor
            let l = label(notice, size: 12, color: .black); l.maximumNumberOfLines = 0
            l.lineBreakMode = .byWordWrapping; l.preferredMaxLayoutWidth = 252
            l.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(l)
            NSLayoutConstraint.activate([
                l.topAnchor.constraint(equalTo: box.topAnchor, constant: 10), l.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
                l.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12), l.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            ])
            stack.addArrangedSubview(padded(box))
        }

        // controls
        let controls = NSStackView(); controls.orientation = .vertical; controls.spacing = 8; controls.alignment = .leading
        func full(_ v: NSView) { v.translatesAutoresizingMaskIntoConstraints = false; controls.addArrangedSubview(v); v.widthAnchor.constraint(equalToConstant: 280).isActive = true }

        switch mode {
        case .idle:
            full(Btn("  Начать запись     ⌘⇧R", symbol: "circle.fill", fg: .black, bg: fgMain, border: fgMain) { [self] in start() })
        case .recording, .paused:
            let pause = Btn(mode == .recording ? " Пауза" : " Дальше", symbol: mode == .recording ? "pause.fill" : "play.fill",
                            fg: fgMain, bg: .black, border: lineCol) { [self] in togglePause() }
            let stopB = Btn(" Закончить", symbol: "stop.fill", fg: .black, bg: fgMain, border: fgMain) { [self] in stop() }
            let row = NSStackView(views: [pause, stopB]); row.distribution = .fillEqually; row.spacing = 6
            full(row)
        case .stopped:
            let mb = Double(elapsed * rates[rateIdx] * 1000 / 8) / 1_048_576
            let meta = savedURL != nil
                ? "~/Movies/Aura · " + String(format: "%.1f MB", Double(savedSize) / 1_048_576)
                : "kbps · ~" + String(format: "%.1f MB", max(0.1, mb))
            var segViews: [NSView] = []
            for (i, k) in rates.enumerated() {
                let sel = i == rateIdx
                segViews.append(Btn(String(k), fg: sel ? .black : fgDim, bg: sel ? fgMain : nil, size: 11, height: 24, radius: 4, mono: true) { [self] in
                    if exporting { return }; rateIdx = i; savedURL = nil; render() })
            }
            let seg = NSStackView(views: segViews); seg.spacing = 2
            let sp = NSView(); sp.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let top = NSStackView(views: [label(meta, size: 11, color: fgDim, mono: true), sp, seg]); top.distribution = .fill; top.alignment = .centerY
            full(top)
            if exporting {
                full(Btn("Кодирую…", fg: fgMuted, bg: NSColor(hex: 0x111111), border: NSColor(hex: 0x262626)) {})
            } else if savedURL == nil {
                full(Btn(" Экспорт в .opus", symbol: "arrow.down.to.line", fg: .black, bg: fgMain, border: fgMain) { [self] in export() })
            } else {
                full(Btn(" Сохранено · новая запись", symbol: "checkmark", fg: fgMain, bg: .black, border: lineCol) { [self] in reset() })
            }
            if savedURL == nil && !exporting {
                full(Btn("Удалить запись", fg: fgMuted, bg: nil, size: 11, height: 24) { [self] in reset() })
            }
        }
        stack.addArrangedSubview(padded(controls, top: 8, h: 10, bottom: 10))

        // footer
        let sep = NSBox(); sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false; stack.addArrangedSubview(sep)
        sep.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let folder = Btn("Открыть папку ↗", fg: fgDim, bg: nil, size: 11, height: 30) { NSWorkspace.shared.open(recDir) }
        let quit = Btn("Выйти ⌘Q", fg: fgDim, bg: nil, size: 11, height: 30) { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"; quit.keyEquivalentModifierMask = .command
        let fsp = NSView(); fsp.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let foot = NSStackView(views: [folder, fsp, quit]); foot.distribution = .fill
        stack.addArrangedSubview(padded(foot, top: 0, h: 6, bottom: 2))

        stack.layoutSubtreeIfNeeded()
        popover.contentSize = NSSize(width: 300, height: stack.fittingSize.height)
    }
}

if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--encode" {
    do { try encodeOpus(src: URL(fileURLWithPath: CommandLine.arguments[2]), dst: URL(fileURLWithPath: CommandLine.arguments[3]), kbps: Int(CommandLine.arguments[4]) ?? 96); print("ok") }
    catch { print("fail: \(error)"); exit(1) }
    exit(0)
}
let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.run()
